import Foundation
import Observation
import StoreKit

/// Aisle+ subscriptions through StoreKit 2: loads the two plans, buys, restores and
/// keeps `isPlus` in sync with the App Store, including renewals and refunds.
///
/// Product IDs must match the auto-renewable subscriptions in App Store Connect
/// (or a local .storekit configuration for testing).
@MainActor
@Observable
final class PlusStore {
    enum Plan: String, CaseIterable, Identifiable {
        case yearly = "app.shopaisle.plus.yearly"
        case monthly = "app.shopaisle.plus.monthly"

        var id: String { rawValue }

        /// Shown until StoreKit returns real prices, and in previews.
        var fallbackPrice: String {
            switch self {
            case .yearly: return "$29.99"
            case .monthly: return "$3.99"
            }
        }
    }

    enum PurchaseResult { case purchased, pending, cancelled }

    private(set) var products: [Plan: Product] = [:]
    private(set) var isPlus = false
    private(set) var isLoading = false
    private(set) var loadError: String?
    /// What the server sees: Aisle+ and today's free photo searches and follow-ups.
    private(set) var serverStatus: PlusServerStatus?

    /// Where the App Store's signed transactions are sent so the server can verify
    /// Aisle+ and lift the free tier's limits. Nil in tests and previews.
    @ObservationIgnored var client: APIClient?
    @ObservationIgnored private var updates: Task<Void, Never>?

    init() {
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                }
                await self?.refreshEntitlement()
            }
        }
    }

    deinit { updates?.cancel() }

    /// Whether StoreKit returned both plans, so buying is possible.
    var canPurchase: Bool { products.count == Plan.allCases.count }

    func price(_ plan: Plan) -> String {
        products[plan]?.displayPrice ?? plan.fallbackPrice
    }

    /// "$2.50 a month" for the yearly plan, from the real price when available.
    var yearlyPerMonth: String {
        guard let yearly = products[.yearly] else { return "$2.50" }
        return (yearly.price / 12).formatted(yearly.priceFormatStyle)
    }

    /// Twelve monthly payments, e.g. "$47.88", to compare with yearly.
    var monthlyPerYear: String {
        guard let monthly = products[.monthly] else { return "$47.88" }
        return (monthly.price * 12).formatted(monthly.priceFormatStyle)
    }

    /// Savings of yearly over twelve monthly payments, rounded, e.g. 37.
    var yearlySavingsPercent: Int {
        guard let yearly = products[.yearly], let monthly = products[.monthly], monthly.price > 0 else { return 37 }
        let ratio = (yearly.price as NSDecimalNumber).doubleValue / ((monthly.price as NSDecimalNumber).doubleValue * 12)
        return max(0, Int(((1 - ratio) * 100).rounded()))
    }

    /// Free-trial length of a plan, e.g. "7-day", when the App Store offers one to this user.
    func trialLabel(_ plan: Plan) async -> String? {
        guard let product = products[plan], let offer = product.subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial,
              await product.subscription?.isEligibleForIntroOffer == true else { return nil }
        let period = offer.period
        switch period.unit {
        case .day: return "\(period.value)-day"
        case .week: return period.value == 1 ? "7-day" : "\(period.value)-week"
        case .month: return "\(period.value)-month"
        case .year: return "\(period.value)-year"
        @unknown default: return nil
        }
    }

    func load() async {
        guard products.isEmpty, !isLoading else {
            await refreshEntitlement()
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let found = try await Product.products(for: Plan.allCases.map(\.rawValue))
            var byPlan: [Plan: Product] = [:]
            for product in found {
                if let plan = Plan(rawValue: product.id) { byPlan[plan] = product }
            }
            products = byPlan
            loadError = byPlan.isEmpty ? "Aisle+ isn't available yet." : nil
        } catch {
            loadError = "Couldn't reach the App Store. Check your connection and try again."
        }
        await refreshEntitlement()
    }

    func purchase(_ plan: Plan) async throws -> PurchaseResult {
        guard let product = products[plan] else { throw PlusError.unavailable }
        switch try await product.purchase() {
        case .success(let verification):
            guard case .verified(let transaction) = verification else { throw PlusError.unverified }
            await transaction.finish()
            await refreshEntitlement()
            return .purchased
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    func restore() async throws {
        try await AppStore.sync()
        await refreshEntitlement()
    }

    func refreshEntitlement() async {
        var active = false
        var signed: [String] = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               Plan(rawValue: transaction.productID) != nil,
               transaction.revocationDate == nil {
                active = true
                signed.append(result.jwsRepresentation)
            }
        }
        isPlus = active
        await syncWithServer(signed)
    }

    /// Tells the server about this device's subscription (or none), and picks up today's
    /// free-tier use. Call again after signing in so Aisle+ follows the account.
    func syncWithServer(_ signed: [String]? = nil) async {
        guard let client else { return }
        var transactions = signed ?? []
        if signed == nil {
            for await result in Transaction.currentEntitlements {
                if case .verified(let transaction) = result, Plan(rawValue: transaction.productID) != nil {
                    transactions.append(result.jwsRepresentation)
                }
            }
        }
        do {
            serverStatus = try await client.syncPlus(transactions: transactions)
        } catch {
            // Offline or not yet verifiable: the App Store's word still unlocks the app's own screens.
            serverStatus = try? await client.plusStatus()
        }
    }

    /// Picks up today's free use after a photo search or follow-up.
    func refreshUsage() async {
        guard let client else { return }
        if let status = try? await client.plusStatus() { serverStatus = status }
    }
}

enum PlusError: LocalizedError {
    case unavailable
    case unverified

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Aisle+ isn't available right now. Try again later."
        case .unverified: return "The App Store couldn't verify that purchase."
        }
    }
}

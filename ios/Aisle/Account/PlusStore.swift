import Foundation
import Observation
import StoreKit

/// Aisle+ subscriptions through StoreKit 2: loads the two plans, buys, restores and
/// keeps `isPlus` in sync with the App Store, including renewals and refunds.
///
/// Aisle+ belongs to an Aisle account, not the Apple ID: purchases carry the account's
/// `plusToken` as their appAccountToken, and only the signed-in account's own purchases
/// (or ones the server says were restored to it) count. Signed out, or after deleting the
/// account, `isPlus` is false even while Apple keeps billing.
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
            case .yearly: return "$39.99"
            case .monthly: return "$5.99"
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

    /// The signed-in account's `plusToken`; nil when signed out. Changing it starts over.
    var accountToken: UUID? {
        didSet {
            guard accountToken != oldValue else { return }
            isPlus = false
            serverStatus = nil
            Task { await refreshEntitlement() }
        }
    }
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

    /// "$3.33 a month" for the yearly plan, from the real price when available.
    var yearlyPerMonth: String {
        guard let yearly = products[.yearly] else { return "$3.33" }
        return (yearly.price / 12).formatted(yearly.priceFormatStyle)
    }

    /// Twelve monthly payments, e.g. "$71.88", to compare with yearly.
    var monthlyPerYear: String {
        guard let monthly = products[.monthly] else { return "$71.88" }
        return (monthly.price * 12).formatted(monthly.priceFormatStyle)
    }

    /// Savings of yearly over twelve monthly payments, rounded, e.g. 37.
    var yearlySavingsPercent: Int {
        guard let yearly = products[.yearly], let monthly = products[.monthly], monthly.price > 0 else { return 44 }
        let ratio = (yearly.price as NSDecimalNumber).doubleValue / ((monthly.price as NSDecimalNumber).doubleValue * 12)
        return max(0, Int(((1 - ratio) * 100).rounded()))
    }

    /// Free-trial length of a plan, e.g. "7-day", when the App Store offers one to this user.
    /// Length of a plan's free trial in days, when this user can get one.
    func trialDays(_ plan: Plan) async -> Int? {
        guard let product = products[plan], let offer = product.subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial,
              await product.subscription?.isEligibleForIntroOffer == true else { return nil }
        let value = offer.period.value
        switch offer.period.unit {
        case .day: return value
        case .week: return value * 7
        case .month: return value * 30
        case .year: return value * 365
        @unknown default: return nil
        }
    }

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
        guard let accountToken else { throw PlusError.signedOut }
        switch try await product.purchase(options: [.appAccountToken(accountToken)]) {
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

    /// Also takes over a subscription Apple is still billing for a deleted account.
    func restore() async throws {
        try await AppStore.sync()
        await refreshEntitlement(claim: true)
    }

    /// Bought for the signed-in account.
    private func isOwn(_ transaction: Transaction) -> Bool {
        accountToken != nil && transaction.appAccountToken == accountToken
    }

    /// The active subscription as the App Store reports it.
    struct Membership: Equatable {
        let plan: Plan
        let isTrial: Bool
        /// When it renews (or the trial converts), or ends if auto-renew is off.
        let nextDate: Date?
        let willRenew: Bool
        let price: String
        let since: Date
    }

    func membership() async -> Membership? {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  let plan = Plan(rawValue: transaction.productID),
                  transaction.revocationDate == nil,
                  isOwn(transaction) || serverStatus?.isPlus == true else { continue }
            var willRenew = true
            if let product = products[plan],
               let status = try? await product.subscription?.status.first,
               case .verified(let renewal) = status.renewalInfo {
                willRenew = renewal.willAutoRenew
            }
            return Membership(
                plan: plan,
                isTrial: transaction.offerType == .introductory,
                nextDate: transaction.expirationDate,
                willRenew: willRenew,
                price: price(plan),
                since: transaction.originalPurchaseDate
            )
        }
        return nil
    }

    func refreshEntitlement(claim: Bool = false) async {
        guard accountToken != nil else {
            isPlus = false
            serverStatus = nil
            return
        }
        var own = false
        var signed: [String] = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               Plan(rawValue: transaction.productID) != nil,
               transaction.revocationDate == nil {
                own = own || isOwn(transaction)
                signed.append(result.jwsRepresentation)
            }
        }
        // Our own purchase counts at once (and offline); a restored one once the server agrees.
        isPlus = own
        await syncWithServer(signed, claim: claim)
        isPlus = own || serverStatus?.isPlus == true
    }

    /// Tells the server about this device's subscription (or none), and picks up today's
    /// free-tier use. Call again after signing in so Aisle+ follows the account.
    func syncWithServer(_ signed: [String]? = nil, claim: Bool = false) async {
        guard let client, accountToken != nil else { return }
        var transactions = signed ?? []
        if signed == nil {
            for await result in Transaction.currentEntitlements {
                if case .verified(let transaction) = result, Plan(rawValue: transaction.productID) != nil {
                    transactions.append(result.jwsRepresentation)
                }
            }
        }
        do {
            serverStatus = try await client.syncPlus(transactions: transactions, claim: claim)
        } catch {
            // Offline or not yet verifiable: the App Store's word still unlocks the app's own screens.
            serverStatus = try? await client.plusStatus()
        }
    }

    /// The free plan's daily limits, from the server when it has answered, otherwise the
    /// server's defaults (backend/app/config.py).
    var freeSearchesPerDay: Int { serverStatus?.search?.limit ?? 5 }
    var freePhotoSearchesPerDay: Int { serverStatus?.photoSearch.limit ?? MemberActivity.freePhotosPerDay }
    /// Follow-up questions per search on the free plan (backend: aisle_free_follow_ups_per_search).
    let freeFollowUpsPerSearch = 1

    /// Picks up today's free use after a photo search or follow-up.
    func refreshUsage() async {
        guard let client else { return }
        if let status = try? await client.plusStatus() { serverStatus = status }
    }
}

enum PlusError: LocalizedError {
    case unavailable
    case unverified
    case signedOut

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Aisle+ isn't available right now. Try again later."
        case .unverified: return "The App Store couldn't verify that purchase."
        case .signedOut: return "Sign in to Aisle to get Aisle+."
        }
    }
}

import Foundation
import RevenueCat
import StoreKit

/// Sends Aisle+ purchases to RevenueCat for revenue and subscriber analytics.
///
/// RevenueCat only watches: PlusStore still buys with StoreKit 2 and the server still
/// decides who has Aisle+ ("observer mode"). Purchases are grouped under the account's
/// `plusToken`, the same ID they carry as their appAccountToken. Off without an API key.
enum PurchaseAnalytics {
    static func start(apiKey: String?) {
        guard let apiKey, !Purchases.isConfigured else { return }
        Purchases.configure(with: .builder(withAPIKey: apiKey)
            .with(purchasesAreCompletedBy: .myApp, storeKitVersion: .storeKit2)
            .build())
    }

    /// Follows the signed-in account, so its purchases show under it on every device.
    static func identify(_ accountToken: UUID?) async {
        guard Purchases.isConfigured else { return }
        if let accountToken {
            _ = try? await Purchases.shared.logIn(accountToken.uuidString)
        } else if !Purchases.shared.isAnonymous {
            _ = try? await Purchases.shared.logOut()
        }
    }

    /// RevenueCat can't see StoreKit 2 purchases made by our own code until we pass them on.
    static func record(_ result: Product.PurchaseResult) async {
        guard Purchases.isConfigured else { return }
        _ = try? await Purchases.shared.recordPurchase(result)
    }

    /// After "Restore purchases", so RevenueCat matches what the App Store just sent.
    static func syncRestored() async {
        guard Purchases.isConfigured else { return }
        _ = try? await Purchases.shared.syncPurchases()
    }
}

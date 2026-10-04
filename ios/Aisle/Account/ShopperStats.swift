import Foundation

/// Small counters for the "Your Aisle" card, kept on the device.
/// Read them in views with @AppStorage on the same keys.
enum ShopperStats {
    static let searchesKey = "aisle.stats.searches"
    static let confirmedKey = "aisle.stats.confirmed"
    static let storesKey = "aisle.stats.stores"
    static let firstUseKey = "aisle.stats.firstUse"

    /// A search that came back with an answer.
    static func recordSearch(storeID: String?, defaults: UserDefaults = .standard) {
        defaults.set(defaults.integer(forKey: searchesKey) + 1, forKey: searchesKey)
        if defaults.object(forKey: firstUseKey) == nil {
            defaults.set(Date().timeIntervalSince1970, forKey: firstUseKey)
        }
        guard let storeID, !storeID.isEmpty else { return }
        var stores = Set(storeIDs(defaults))
        stores.insert(storeID)
        defaults.set(stores.sorted().joined(separator: ","), forKey: storesKey)
    }

    /// "Found it" or a correction the server accepted.
    static func recordConfirmation(defaults: UserDefaults = .standard) {
        defaults.set(defaults.integer(forKey: confirmedKey) + 1, forKey: confirmedKey)
    }

    static func storeCount(_ joined: String) -> Int {
        joined.split(separator: ",").count
    }

    static func reset(defaults: UserDefaults = .standard) {
        for key in [searchesKey, confirmedKey, storesKey, firstUseKey] {
            defaults.removeObject(forKey: key)
        }
    }

    private static func storeIDs(_ defaults: UserDefaults) -> [String] {
        (defaults.string(forKey: storesKey) ?? "").split(separator: ",").map(String.init)
    }
}

import Foundation

/// Everything Aisle keeps on the phone for an account: lists, recent and past searches,
/// trips, confirmed spots, the stats on the You and Aisle+ tabs, the chosen store and
/// saved maps. It belongs to one account, so it's erased when that account is deleted,
/// and when a different account signs in on this phone.
@MainActor
enum LocalAccountData {
    /// The account the data on this phone belongs to.
    static let ownerKey = "aisle.dataOwner"

    /// Settings for the phone rather than the account, kept even after a deletion.
    static let deviceSettings: Set<String> = [
        DeviceIdentity.defaultsKey, AppearancePreference.defaultsKey, AnalyticsClient.enabledKey,
    ]

    struct Stores {
        let lists: ShoppingListStore
        let recents: RecentSearches
        let storeSelection: StoreSelection
        let offlineMaps: OfflineMaps?
    }

    /// The account was deleted: back to a fresh install, onboarding included.
    static func eraseForDeletedAccount(_ stores: Stores, defaults: UserDefaults = .standard) {
        erase(stores, keeping: deviceSettings, defaults: defaults)
    }

    /// Call when an account signs in. Data from a different account is erased first; the
    /// new account's own sign-up (onboarding done, terms accepted) is kept.
    static func adopt(accountID: String, _ stores: Stores, defaults: UserDefaults = .standard) {
        if let owner = defaults.string(forKey: ownerKey), owner != accountID {
            erase(stores, keeping: deviceSettings.union([
                AccountStore.defaultsKey, OnboardingFlow.completedKey, Legal.acceptedVersionKey, Legal.acceptedAtKey,
            ]), defaults: defaults)
        }
        defaults.set(accountID, forKey: ownerKey)
    }

    private static func erase(_ stores: Stores, keeping kept: Set<String>, defaults: UserDefaults) {
        SearchHistory.shared.clear()
        TripHistory.shared.clear()
        ContributionLog.shared.clear()
        MemberActivity.reset(defaults: defaults)
        stores.recents.clear()
        stores.storeSelection.clear()
        stores.lists.eraseAll()
        stores.offlineMaps?.removeAll()
        // Find's per-session recents live in their own suite.
        UserDefaults(suiteName: FindModel.ephemeralSuite)?.removePersistentDomain(forName: FindModel.ephemeralSuite)
        // Last, so it also catches what the stores above just wrote (and any key added later).
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("aisle.") && !kept.contains(key) {
            defaults.removeObject(forKey: key)
        }
    }
}

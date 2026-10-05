import XCTest
@testable import Aisle

@MainActor
final class LocalAccountDataTests: XCTestCase {
    private func stores(_ defaults: UserDefaults) -> LocalAccountData.Stores {
        LocalAccountData.Stores(
            lists: ShoppingListStore(defaults: defaults),
            recents: RecentSearches(defaults: defaults),
            storeSelection: StoreSelection(defaults: defaults),
            offlineMaps: OfflineMaps(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("LocalAccountDataTests-\(UUID().uuidString)"))
        )
    }

    /// Someone who has used Aisle for a while: lists, searches, a store, stats and settings.
    private func used(_ defaults: UserDefaults) -> LocalAccountData.Stores {
        let stores = stores(defaults)
        _ = stores.lists.createList(named: "Costco")
        stores.recents.record("maple syrup")
        stores.storeSelection.select(Fixtures.store)
        ShopperStats.recordSearch(storeID: "1", defaults: defaults)
        ShopperStats.recordConfirmation(defaults: defaults)
        MemberActivity.recordFollowUp(question: "and eggs?", answer: "Dairy.", defaults: defaults)
        defaults.set(true, forKey: OnboardingFlow.completedKey)
        defaults.set("2026-10", forKey: Legal.acceptedVersionKey)
        defaults.set(AppearancePreference.dark.rawValue, forKey: AppearancePreference.defaultsKey)
        defaults.set(false, forKey: AnalyticsClient.enabledKey)
        defaults.set("install-1", forKey: DeviceIdentity.defaultsKey)
        return stores
    }

    func testDeletingTheAccountResetsEverythingButPhoneSettings() {
        let defaults = UserDefaults.fresh("LocalAccountDataTests.Delete")
        let stores = used(defaults)

        LocalAccountData.eraseForDeletedAccount(stores, defaults: defaults)

        XCTAssertEqual(stores.lists.lists.map(\.name), ["My list"])
        XCTAssertTrue(stores.lists.items.isEmpty)
        XCTAssertTrue(stores.recents.queries.isEmpty)
        XCTAssertNil(stores.storeSelection.current)
        XCTAssertEqual(defaults.integer(forKey: ShopperStats.searchesKey), 0)
        XCTAssertEqual(defaults.integer(forKey: ShopperStats.confirmedKey), 0)
        XCTAssertEqual(defaults.integer(forKey: MemberActivity.followUpsKey), 0)
        XCTAssertTrue(SearchHistory.shared.entries.isEmpty)
        XCTAssertTrue(ContributionLog.shared.entries.isEmpty)
        // Onboarding and the terms start over...
        XCTAssertFalse(defaults.bool(forKey: OnboardingFlow.completedKey))
        XCTAssertNil(defaults.string(forKey: Legal.acceptedVersionKey))
        // ...but the phone's own settings stay.
        XCTAssertEqual(defaults.string(forKey: AppearancePreference.defaultsKey), "dark")
        XCTAssertEqual(defaults.object(forKey: AnalyticsClient.enabledKey) as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: DeviceIdentity.defaultsKey), "install-1")
        // And a relaunch finds nothing either.
        XCTAssertEqual(ShoppingListStore(defaults: defaults).lists.map(\.name), ["My list"])
        XCTAssertNil(StoreSelection(defaults: defaults).current)
    }

    func testTheSameAccountSigningBackInKeepsItsData() {
        let defaults = UserDefaults.fresh("LocalAccountDataTests.Same")
        let stores = used(defaults)
        LocalAccountData.adopt(accountID: "7", stores, defaults: defaults)
        LocalAccountData.adopt(accountID: "7", stores, defaults: defaults)
        XCTAssertEqual(stores.lists.lists.count, 2)
        XCTAssertEqual(defaults.integer(forKey: ShopperStats.searchesKey), 1)
    }

    func testAnotherAccountStartsAtZeroWithoutRedoingSignUp() {
        let defaults = UserDefaults.fresh("LocalAccountDataTests.Switch")
        let stores = used(defaults)
        LocalAccountData.adopt(accountID: "7", stores, defaults: defaults)
        defaults.set(Data("cached".utf8), forKey: AccountStore.defaultsKey)

        LocalAccountData.adopt(accountID: "8", stores, defaults: defaults)

        XCTAssertEqual(stores.lists.lists.map(\.name), ["My list"])
        XCTAssertTrue(stores.recents.queries.isEmpty)
        XCTAssertEqual(defaults.integer(forKey: ShopperStats.searchesKey), 0)
        // The new account just signed up: it stays signed in and past onboarding and terms.
        XCTAssertNotNil(defaults.data(forKey: AccountStore.defaultsKey))
        XCTAssertTrue(defaults.bool(forKey: OnboardingFlow.completedKey))
        XCTAssertEqual(defaults.string(forKey: Legal.acceptedVersionKey), "2026-10")
        XCTAssertEqual(defaults.string(forKey: LocalAccountData.ownerKey), "8")
    }

    func testAGuestsListsHistoryAndStoreCarryIntoTheirNewAccount() {
        let defaults = UserDefaults.fresh("LocalAccountDataTests.Guest")
        let stores = used(defaults)
        defaults.set(true, forKey: GuestMode.key)
        defaults.set(true, forKey: GuestAccountCard.dismissedKey)
        XCTAssertNil(defaults.string(forKey: LocalAccountData.ownerKey))

        LocalAccountData.adopt(accountID: "7", stores, defaults: defaults)

        XCTAssertEqual(stores.lists.lists.count, 2)
        XCTAssertEqual(stores.recents.queries, ["maple syrup"])
        XCTAssertEqual(stores.storeSelection.current?.id, Fixtures.store.id)
        XCTAssertEqual(defaults.integer(forKey: ShopperStats.searchesKey), 1)
        XCTAssertEqual(defaults.string(forKey: Legal.acceptedVersionKey), "2026-10")
        XCTAssertEqual(defaults.string(forKey: LocalAccountData.ownerKey), "7")
        // And it all survives a relaunch.
        XCTAssertEqual(ShoppingListStore(defaults: defaults).lists.count, 2)
        XCTAssertNotNil(StoreSelection(defaults: defaults).current)
    }

    func testDeletingAnAccountMadeFromGuestStartsOnboardingOver() {
        let defaults = UserDefaults.fresh("LocalAccountDataTests.GuestDelete")
        let stores = used(defaults)
        defaults.set(true, forKey: GuestMode.key)
        LocalAccountData.adopt(accountID: "7", stores, defaults: defaults)

        LocalAccountData.eraseForDeletedAccount(stores, defaults: defaults)

        XCTAssertFalse(defaults.bool(forKey: GuestMode.key))
        XCTAssertFalse(defaults.bool(forKey: OnboardingFlow.completedKey))
    }

    func testDataFromBeforeSignUpGoesToTheFirstAccount() {
        let defaults = UserDefaults.fresh("LocalAccountDataTests.First")
        let stores = used(defaults)
        LocalAccountData.adopt(accountID: "7", stores, defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: ShopperStats.searchesKey), 1)
        XCTAssertEqual(stores.lists.lists.count, 2)
    }
}

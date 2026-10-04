import XCTest
@testable import Aisle

@MainActor
final class StoreSelectionTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "AisleTests.StoreSelection"

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testStartsEmpty() {
        XCTAssertNil(StoreSelection(defaults: defaults).current)
    }

    func testSelectionPersistsAcrossInstances() {
        StoreSelection(defaults: defaults).select(Fixtures.store)
        // A fresh instance simulates a relaunch.
        XCTAssertEqual(StoreSelection(defaults: defaults).current, Fixtures.store)
    }

    func testRefreshUpdatesSameStoreAndPersists() {
        let selection = StoreSelection(defaults: defaults)
        selection.select(Fixtures.store)
        let fresh = Self.copy(of: Fixtures.store, id: Fixtures.store.id, logo: URL(string: "https://img.logo.dev/target.com"))
        selection.refresh(fresh)
        XCTAssertEqual(selection.current?.retailerLogoURL, fresh.retailerLogoURL)
        XCTAssertEqual(StoreSelection(defaults: defaults).current, fresh)
    }

    func testRefreshIgnoresADifferentStore() {
        let selection = StoreSelection(defaults: defaults)
        selection.select(Fixtures.store)
        selection.refresh(Self.copy(of: Fixtures.store, id: "other", logo: nil))
        XCTAssertEqual(selection.current, Fixtures.store)
    }

    private static func copy(of store: Store, id: String, logo: URL?) -> Store {
        Store(
            id: id, name: store.name, address: store.address, latitude: store.latitude,
            longitude: store.longitude, distanceMiles: store.distanceMiles,
            retailerName: store.retailerName, retailerLogoURL: logo
        )
    }

    func testClearRemovesPersistedStore() {
        let selection = StoreSelection(defaults: defaults)
        selection.select(Fixtures.store)
        selection.clear()
        XCTAssertNil(StoreSelection(defaults: defaults).current)
    }

    func testCorruptDataIsIgnored() {
        defaults.set(Data("not json".utf8), forKey: StoreSelection.defaultsKey)
        XCTAssertNil(StoreSelection(defaults: defaults).current)
    }
}

import XCTest
@testable import Aisle

final class OfflineMapsTests: XCTestCase {
    private var directory: URL!
    private var maps: OfflineMaps!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        maps = OfflineMaps(directory: directory)
        maps.isEnabled = true
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private let layout = StoreLayout(
        storeID: 2, entrance: .init(x: 0.5, y: 0), checkout: .init(x: 0.9, y: 0),
        zones: [.init(id: 10, name: "Produce", x: 0.1, y: 0.1, source: "template"),
                .init(id: 11, name: "Dairy", x: 0.2, y: 0.9, source: "template")],
        approximate: true
    )

    private func route(_ items: [ListItem]) -> RoutePlan {
        func stopItem(_ item: ListItem) -> RouteStopItem {
            RouteStopItem(id: item.id.uuidString, text: item.text, aisle: nil, section: nil,
                          neighbors: [], confidence: .medium, source: .fallback)
        }
        return RoutePlan(storeID: 2, stops: [
            RouteStop(order: 1, zoneID: 11, department: "Dairy", x: 0.2, y: 0.9, items: [stopItem(items[0])]),
            RouteStop(order: 2, zoneID: 10, department: "Produce", x: 0.1, y: 0.1, items: [stopItem(items[1])]),
        ], unplaced: [], distance: 1)
    }

    func testSavedMapsAnswerWhenOffline() async throws {
        let stub = StubAPI()
        let api = OfflineAwareAPI(base: stub, maps: maps)
        let milk = ListItem(text: "Milk"), bananas = ListItem(text: "bananas"), cake = ListItem(text: "cake")
        stub.routeResult = .success(route([milk, bananas]))
        _ = try await api.planRoute(storeID: "2", items: [milk, bananas])
        maps.save(layout: layout, storeID: "2")
        _ = try await api.searchItem(query: "maple syrup", storeID: "2")

        // Offline: a route from saved spots, nearest first from the entrance.
        stub.routeResult = .failure(APIError.offline)
        stub.searchItemResult = .failure(APIError.transport("down"))
        let offline = try await api.planRoute(storeID: "2", items: [ListItem(text: "milk "), ListItem(text: "Bananas"), cake])
        XCTAssertTrue(offline.isOffline)
        XCTAssertEqual(offline.stops.map(\.department), ["Produce", "Dairy"])
        XCTAssertEqual(offline.unplaced.map(\.text), ["cake"])
        let answer = try await api.searchItem(query: "Maple Syrup", storeID: "2")
        XCTAssertEqual(answer.item, Fixtures.mapleSyrup.item)

        // Saved across launches.
        let reopened = OfflineMaps(directory: directory)
        reopened.isEnabled = true
        XCTAssertEqual(reopened.layout(storeID: "2"), layout)
        XCTAssertEqual(reopened.savedStoreIDs, ["2"])
    }

    func testNothingIsSavedOrServedWithoutAislePlus() async throws {
        maps.isEnabled = false
        let stub = StubAPI()
        let api = OfflineAwareAPI(base: stub, maps: maps)
        _ = try await api.searchItem(query: "maple syrup", storeID: "2")
        maps.save(layout: layout, storeID: "2")
        stub.searchItemResult = .failure(APIError.offline)
        do {
            _ = try await api.searchItem(query: "maple syrup", storeID: "2")
            XCTFail("Should have failed offline")
        } catch {
            XCTAssertEqual(error as? APIError, .offline)
        }
        maps.isEnabled = true
        XCTAssertNil(maps.layout(storeID: "2"))
    }

    func testServerErrorsArentHiddenBehindSavedMaps() async throws {
        let stub = StubAPI()
        let api = OfflineAwareAPI(base: stub, maps: maps)
        _ = try await api.searchItem(query: "maple syrup", storeID: "2")
        stub.searchItemResult = .failure(APIError.plusRequired(feature: "x", message: "y"))
        do {
            _ = try await api.searchItem(query: "maple syrup", storeID: "2")
            XCTFail("A 402 should reach the app")
        } catch {
            XCTAssertEqual(error as? APIError, .plusRequired(feature: "x", message: "y"))
        }
    }

    func testRemoveAll() {
        maps.save(layout: layout, storeID: "2")
        maps.removeAll()
        XCTAssertTrue(maps.savedStoreIDs.isEmpty)
        XCTAssertNil(OfflineMaps(directory: directory).layout(storeID: "2"))
    }
}

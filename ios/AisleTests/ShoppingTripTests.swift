import XCTest
@testable import Aisle

@MainActor
final class ShoppingTripTests: XCTestCase {
    private var list: ShoppingListStore!
    private let suite = "AisleTests.Trip"

    override func setUp() async throws {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        list = ShoppingListStore(defaults: defaults)
        list.add(["milk", "eggs", "bananas", "flux capacitor"].map {
            ParsedListItem(text: $0, quantity: nil, category: nil)
        })
    }

    private var store: Store {
        Store(id: "2", name: "Trader Joe's", address: "", latitude: 0, longitude: 0, distanceMiles: nil, retailerName: nil)
    }

    private func plan() -> RoutePlan {
        let ids = list.items.map { $0.id.uuidString }
        func item(_ index: Int) -> RouteStopItem {
            RouteStopItem(id: ids[index], text: list.items[index].text, aisle: nil, section: nil,
                          neighbors: [], confidence: .medium, source: .fallback)
        }
        return RoutePlan(storeID: 2, stops: [
            RouteStop(order: 1, zoneID: 10, department: "Produce", x: 0.1, y: 0.2, items: [item(2)]),
            RouteStop(order: 2, zoneID: 11, department: "Dairy & Eggs", x: 0.2, y: 0.9, items: [item(0), item(1)]),
        ], unplaced: [UnplacedItem(id: ids[3], text: "flux capacitor", reason: .unknown)], distance: 2)
    }

    func testRouteLoadsAndWalksStopsInOrder() async {
        let api = StubAPI()
        api.routeResult = .success(plan())
        let trip = ShoppingTripModel(api: api, store: store, list: list)
        await trip.start()
        XCTAssertEqual(trip.phase, .shopping)
        XCTAssertEqual(api.routeRequests.first?.1.count, 4)
        XCTAssertEqual(trip.totalCount, 4)
        XCTAssertEqual(trip.currentStopIndex, 0)
        XCTAssertEqual(trip.upcomingStops.map(\.department), ["Dairy & Eggs"])

        trip.markFound(trip.stops[0].items[0].id)
        XCTAssertEqual(trip.currentStopIndex, 1)
        XCTAssertTrue(list.items[2].isDone, "Found items are checked off the list")

        trip.markFound(trip.stops[1].items[0].id)
        trip.skip(trip.stops[1].items[1].id)
        XCTAssertNil(trip.currentStopIndex)
        XCTAssertEqual(trip.pendingUnplaced.map(\.text), ["flux capacitor"])
        XCTAssertFalse(trip.isFinished)

        trip.skip(trip.unplaced[0].id)
        XCTAssertTrue(trip.isFinished)
        XCTAssertEqual(trip.foundCount, 2)
        XCTAssertEqual(trip.skippedCount, 2)
        XCTAssertEqual(trip.progress, 1)
        XCTAssertEqual(trip.skippedTexts, ["eggs", "flux capacitor"])
    }

    func testFoundAtRoutedStopReportsZone() async throws {
        let api = StubAPI()
        api.routeResult = .success(plan())
        let trip = ShoppingTripModel(api: api, store: store, list: list)
        await trip.start()
        trip.markFound(trip.stops[1].items[0].id)
        // The report is sent in the background.
        for _ in 0..<50 where api.feedbackBodies.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(api.feedbackBodies, [FeedbackBody(storeID: 2, item: "milk", verdict: .found, zoneID: 11)])
    }

    func testRetrySkippedAndUndo() async {
        let api = StubAPI()
        api.routeResult = .success(plan())
        let trip = ShoppingTripModel(api: api, store: store, list: list)
        await trip.start()
        let bananas = trip.stops[0].items[0].id
        trip.skip(bananas)
        XCTAssertEqual(trip.currentStopIndex, 1)
        trip.retrySkipped()
        XCTAssertEqual(trip.currentStopIndex, 0)

        trip.markFound(bananas)
        trip.undo(bananas)
        XCTAssertEqual(trip.status(of: bananas), .pending)
        XCTAssertFalse(list.items[2].isDone)
    }

    func testRouteFailureOffersListOrder() async {
        let api = StubAPI()
        api.routeResult = .failure(APIError.transport("offline"))
        let trip = ShoppingTripModel(api: api, store: store, list: list)
        await trip.start()
        guard case .failed = trip.phase else { return XCTFail("Expected failure") }
        trip.shopWithoutRoute()
        XCTAssertEqual(trip.phase, .shopping)
        XCTAssertTrue(trip.isUnrouted)
        XCTAssertEqual(trip.stops.first?.items.map(\.text), ["milk", "eggs", "bananas", "flux capacitor"])
        trip.markFound(trip.stops[0].items[0].id)
        XCTAssertTrue(api.feedbackBodies.isEmpty, "No zone feedback without a route")
    }

    func testOnlyRemainingItemsAreRouted() async {
        list.setDone(list.items[0].id, true)
        let api = StubAPI()
        let trip = ShoppingTripModel(api: api, store: store, list: list)
        await trip.start()
        XCTAssertEqual(api.routeRequests.first?.1.map(\.text), ["eggs", "bananas", "flux capacitor"])
    }

    func testEmptyListFails() async {
        list.clearAll()
        let trip = ShoppingTripModel(api: StubAPI(), store: store, list: list)
        await trip.start()
        guard case .failed = trip.phase else { return XCTFail("Expected failure") }
    }
}

final class RouteClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testPlanRouteRequestAndDecoding() async throws {
        StubURLProtocol.respond(json: """
        {"store_id":2,"stops":[{"order":1,"zone_id":17,"department":"Dairy & Eggs","x":0.15,"y":0.9,
        "items":[{"id":"A","text":"milk","aisle":null,"section":null,"neighbors":["butter"],
        "confidence":"medium","source":"fallback"}]}],
        "unplaced":[{"id":"B","text":"hammer","reason":"not_carried"}],"distance":1.5}
        """)
        let client = APIClient(baseURL: URL(string: "http://127.0.0.1:8000")!, session: StubURLProtocol.makeSession())
        let item = ListItem(text: "milk")
        let plan = try await client.planRoute(storeID: "2", items: [item])
        XCTAssertEqual(plan.stops.first?.department, "Dairy & Eggs")
        XCTAssertEqual(plan.stops.first?.zoneID, 17)
        XCTAssertEqual(plan.unplaced.first?.reason, .notCarried)

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/route")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.bodyData)) as? [String: Any])
        XCTAssertEqual(json["store_id"] as? Int, 2)
        let items = try XCTUnwrap(json["items"] as? [[String: Any]])
        XCTAssertEqual(items.first?["id"] as? String, item.id.uuidString)
        XCTAssertEqual(items.first?["text"] as? String, "milk")
    }
}

// MARK: - Multi-store trips

extension ShoppingTripTests {

    private var homeDepot: Store {
        Store(id: "9", name: "Home Depot South Philly", address: "", latitude: 0, longitude: 0,
              distanceMiles: nil, retailerName: "Home Depot")
    }

    private func multiPlan() -> MultiRoutePlan {
        let ids = list.items.map { $0.id.uuidString }
        func item(_ index: Int) -> RouteStopItem {
            RouteStopItem(id: ids[index], text: list.items[index].text, aisle: nil, section: nil,
                          neighbors: [], confidence: .medium, source: .fallback)
        }
        return MultiRoutePlan(legs: [
            .init(storeID: 2, storeName: "Trader Joe's", retailerName: "Trader Joe's", stops: [
                RouteStop(order: 1, zoneID: 10, department: "Dairy & Eggs", x: 0.2, y: 0.9, items: [item(0), item(1)]),
            ], unplaced: [], distance: 1),
            .init(storeID: 9, storeName: "Home Depot South Philly", retailerName: "Home Depot", stops: [
                RouteStop(order: 1, zoneID: 40, department: "Garden", x: 0.5, y: 0.5, items: [item(2)]),
            ], unplaced: [], distance: 1),
        ], unplaced: [UnplacedItem(id: ids[3], text: "flux capacitor", reason: .unknown)])
    }

    func testMultiStoreTripFinishesOneStoreThenMovesOn() async {
        let api = StubAPI()
        api.multiRouteResult = .success(multiPlan())
        let trip = ShoppingTripModel(api: api, stores: [store, homeDepot], list: list)
        await trip.start()
        XCTAssertEqual(api.multiRouteRequests.first?.0, ["2", "9"])
        XCTAssertTrue(trip.isMultiStore)
        XCTAssertEqual(trip.totalCount, 4)
        XCTAssertEqual(trip.storeName, "Trader Joe's")
        XCTAssertNil(trip.nextLeg)
        XCTAssertTrue(trip.unplaced.isEmpty, "Items no store carries wait for the last store")

        trip.markFound(trip.stops[0].items[0].id)
        trip.skip(trip.stops[0].items[1].id)
        XCTAssertTrue(trip.isCurrentLegDone)
        XCTAssertEqual(trip.nextLeg?.store.id, "9")
        XCTAssertFalse(trip.isFinished)

        await trip.goToNextStore()
        XCTAssertEqual(trip.storeName, "Home Depot South Philly")
        XCTAssertEqual(trip.currentStopIndex, 0)
        XCTAssertEqual(trip.unplaced.map(\.text), ["flux capacitor"])
        XCTAssertTrue(trip.isNowhere(trip.unplaced[0].id))

        trip.markFound(trip.stops[0].items[0].id)
        trip.skip(trip.unplaced[0].id)
        XCTAssertTrue(trip.isFinished)
        XCTAssertEqual(trip.skippedTexts, ["eggs", "flux capacitor"])

        // Looking again goes back to the first store with something skipped.
        trip.retrySkipped()
        XCTAssertEqual(trip.storeName, "Trader Joe's")
        XCTAssertEqual(trip.pendingItems(in: trip.stops[0]).map(\.text), ["eggs"])
    }

    func testMultiStoreTripWithoutAislePlusFails() async {
        let trip = ShoppingTripModel(api: StubAPI(), stores: [store, homeDepot], list: list)
        await trip.start()
        XCTAssertEqual(trip.phase, .failed("Shopping more than one store in a trip is part of Aisle+."))
        trip.shopWithoutRoute()
        XCTAssertEqual(trip.phase, .shopping)
        XCTAssertEqual(trip.totalCount, 4)
    }
}

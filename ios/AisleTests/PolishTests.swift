import SwiftUI
import XCTest
@testable import Aisle

@MainActor
final class RecentSearchesTests: XCTestCase {
    func testMostRecentFirstDedupedAndCapped() {
        let defaults = UserDefaults.fresh("AisleTests.Recents")
        let recents = RecentSearches(defaults: defaults)
        for query in ["milk", "eggs", " Milk ", ""] { recents.record(query) }
        XCTAssertEqual(recents.queries, ["Milk", "eggs"])
        for n in 0..<20 { recents.record("item \(n)") }
        XCTAssertEqual(recents.queries.count, RecentSearches.limit)
        XCTAssertEqual(recents.queries.first, "item 19")
        XCTAssertEqual(RecentSearches(defaults: defaults).queries, recents.queries, "Persists across launches")
        recents.remove("item 19")
        XCTAssertEqual(recents.queries.first, "item 18")
        recents.clear()
        XCTAssertTrue(RecentSearches(defaults: defaults).queries.isEmpty)
    }
}

@MainActor
final class SearchCacheTests: XCTestCase {
    func testExpiresAndNormalizesKeys() {
        var now = Date(timeIntervalSince1970: 0)
        let cache = SearchCache(ttl: 60, now: { now })
        cache.store(Fixtures.mapleSyrup, query: "Maple  Syrup", storeID: "2")
        XCTAssertEqual(cache.result(query: "maple syrup", storeID: "2"), Fixtures.mapleSyrup)
        XCTAssertNil(cache.result(query: "maple syrup", storeID: "3"), "Cache is per store")
        now = now.addingTimeInterval(61)
        XCTAssertNil(cache.result(query: "maple syrup", storeID: "2"))
    }

    func testInvalidateByItem() {
        let cache = SearchCache()
        cache.store(Fixtures.mapleSyrup, query: "maple syrup", storeID: "2")
        cache.store(Fixtures.mapleSyrup, query: "organic maple syrup", storeID: "2")
        cache.invalidate(item: "Maple Syrup", storeID: "2")
        XCTAssertNil(cache.result(query: "maple syrup", storeID: "2"))
        XCTAssertNil(cache.result(query: "organic maple syrup", storeID: "2"))
    }
}

@MainActor
final class FindModelPolishTests: XCTestCase {
    private func makeModel(_ api: StubAPI, analytics: RecordingAnalytics? = nil) -> FindModel {
        FindModel(api: api, analytics: analytics ?? RecordingAnalytics(),
                  recents: RecentSearches(defaults: .fresh("AisleTests.FindRecents")))
    }

    func testRepeatSearchUsesCacheAndRecordsRecent() async {
        let api = StubAPI()
        let analytics = RecordingAnalytics()
        let model = makeModel(api, analytics: analytics)
        model.query = "maple syrup"
        await model.search(storeID: "2")
        await model.search(storeID: "2")
        XCTAssertEqual(api.itemSearches.count, 1)
        XCTAssertEqual(model.recents.queries, ["maple syrup"])
        XCTAssertEqual(analytics.names, [.searchSubmitted, .searchSubmitted])
        XCTAssertEqual(analytics.events.last?.1["cached"], .bool(true))
        XCTAssertEqual(analytics.events.first?.1["source"], .string("fallback"))
        XCTAssertNil(analytics.events.first?.1["query"], "Analytics never carries the query text")
    }

    func testFeedbackInvalidatesCache() async {
        let api = StubAPI()
        let model = makeModel(api)
        model.query = "maple syrup"
        await model.search(storeID: "2")
        await model.confirmFound(storeID: "2")
        await model.search(storeID: "2")
        XCTAssertEqual(api.itemSearches.count, 2)
    }

    func testRecentSearchTap() async {
        let api = StubAPI()
        let analytics = RecordingAnalytics()
        let model = makeModel(api, analytics: analytics)
        await model.searchRecent("honey", storeID: "2")
        XCTAssertEqual(model.query, "honey")
        XCTAssertEqual(api.itemSearches.first?.0, "honey")
        XCTAssertEqual(analytics.names.first, .recentSearchTapped)
    }

    func testOfflineErrorMessageAndAnalytics() async {
        let api = StubAPI()
        api.searchItemResult = .failure(APIError.offline)
        let analytics = RecordingAnalytics()
        let model = makeModel(api, analytics: analytics)
        model.query = "milk"
        await model.search(storeID: "2")
        XCTAssertEqual(model.phase, .failed("You're offline. Check your connection and try again."))
        XCTAssertEqual(analytics.events.last?.0, .searchFailed)
        XCTAssertEqual(analytics.events.last?.1["error"], .string("offline"))
    }
}

@MainActor
final class AnalyticsClientTests: XCTestCase {
    func testBatchesAndFlushes() async {
        let api = StubAPI()
        let client = AnalyticsClient(api: api, defaults: .fresh("AisleTests.Analytics"))
        client.track(.appOpened)
        client.track(.shoppingStarted, ["items": 4, "unrouted": false])
        XCTAssertEqual(client.queue.count, 2)
        await client.flush()
        XCTAssertEqual(api.sentEventBatches.first?.map(\.name), [.appOpened, .shoppingStarted])
        XCTAssertTrue(client.queue.isEmpty)
    }

    func testFailedFlushKeepsEvents() async {
        let api = StubAPI()
        api.eventsError = APIError.offline
        let client = AnalyticsClient(api: api, defaults: .fresh("AisleTests.Analytics2"))
        client.track(.appOpened)
        await client.flush()
        XCTAssertEqual(client.queue.count, 1)
    }

    func testOptOutDropsEvents() async {
        let defaults = UserDefaults.fresh("AisleTests.Analytics3")
        defaults.set(false, forKey: AnalyticsClient.enabledKey)
        let api = StubAPI()
        let client = AnalyticsClient(api: api, defaults: defaults)
        client.track(.appOpened)
        await client.flush()
        XCTAssertTrue(client.queue.isEmpty)
        XCTAssertTrue(api.sentEventBatches.isEmpty)
    }

    func testQueueIsBounded() {
        let defaults = UserDefaults.fresh("AisleTests.Analytics4")
        let api = StubAPI()
        api.eventsError = APIError.offline
        let client = AnalyticsClient(api: api, defaults: defaults)
        for _ in 0..<(AnalyticsClient.maxQueued + 5) { client.track(.shoppingItemFound) }
        XCTAssertEqual(client.queue.count, AnalyticsClient.maxQueued)
    }

    func testEventEncodingMatchesServer() throws {
        let event = AnalyticsEvent(
            name: .searchSubmitted, occurredAt: Date(timeIntervalSince1970: 0),
            properties: ["source": "fallback", "cached": true, "count": 3]
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(AnalyticsBatchBody(events: [event]))) as? [String: Any]
        )
        let first = try XCTUnwrap((json["events"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["name"] as? String, "search_submitted")
        XCTAssertEqual(first["occurred_at"] as? String, "1970-01-01T00:00:00Z")
        let properties = try XCTUnwrap(first["properties"] as? [String: Any])
        XCTAssertEqual(properties["cached"] as? Bool, true)
        XCTAssertEqual(properties["count"] as? Int, 3)
    }
}

@MainActor
final class TripAnalyticsTests: XCTestCase {
    func testTripEventsCarryCountsOnly() async {
        let list = ShoppingListStore(defaults: .fresh("AisleTests.TripAnalytics"))
        list.add([ParsedListItem(text: "milk", quantity: nil, category: nil)])
        let analytics = RecordingAnalytics()
        let store = Store(id: "2", name: "TJ", address: "", latitude: 0, longitude: 0, distanceMiles: nil, retailerName: nil)
        let trip = ShoppingTripModel(api: StubAPI(), store: store, list: list, analytics: analytics)
        await trip.start()
        trip.markFound(trip.stops[0].items[0].id)
        XCTAssertEqual(analytics.names, [.shoppingStarted, .shoppingItemFound, .shoppingFinished])
        XCTAssertEqual(analytics.events.last?.1["found"], .int(1))
    }
}

final class ErrorMappingTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func error(for code: URLError.Code) async -> Error? {
        StubURLProtocol.handler = { _ in throw URLError(code) }
        let client = APIClient(baseURL: URL(string: "http://127.0.0.1:8000")!, session: StubURLProtocol.makeSession())
        do {
            _ = try await client.health()
            return nil
        } catch {
            return error
        }
    }

    func testOfflineAndTimeoutAreDistinct() async {
        let offline = await error(for: .notConnectedToInternet)
        let timeout = await error(for: .timedOut)
        XCTAssertEqual(offline as? APIError, .offline)
        XCTAssertEqual(timeout as? APIError, .timeout)
    }

    func testServerErrorsHaveFriendlyText() {
        XCTAssertEqual(APIError.httpStatus(503).errorDescription, "Aisle is having trouble right now. Try again in a moment.")
        XCTAssertEqual(APIError.httpStatus(503).kind, "http_503")
    }
}

final class AppearanceTests: XCTestCase {
    func testColorSchemes() {
        XCTAssertNil(AppearancePreference.system.colorScheme)
        XCTAssertEqual(AppearancePreference.light.colorScheme, .light)
        XCTAssertEqual(AppearancePreference.dark.colorScheme, .dark)
    }
}

final class AnalyticsNamesContractTests: XCTestCase {
    /// Must match ANALYTICS_EVENT_NAMES in backend/app/schemas.py.
    func testEventNames() {
        XCTAssertEqual(Set(AnalyticsEventName.allCases.map(\.rawValue)), [
            "app_opened", "store_selected", "search_submitted", "search_failed", "recent_search_tapped",
            "feedback_sent", "list_items_added", "shopping_started", "shopping_item_found",
            "shopping_item_skipped", "shopping_finished", "follow_up_sent",
        ])
    }
}

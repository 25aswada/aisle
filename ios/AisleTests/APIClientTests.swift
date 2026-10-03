import XCTest
@testable import Aisle

final class APIClientTests: XCTestCase {
    private var client: APIClient!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        client = APIClient(baseURL: URL(string: "http://127.0.0.1:8000")!, session: StubURLProtocol.makeSession())
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testHealthHitsHealthEndpoint() async throws {
        StubURLProtocol.respond(json: #"{"status":"ok"}"#)
        let health = try await client.health()
        XCTAssertTrue(health.isOK)
        XCTAssertEqual(StubURLProtocol.requests.first?.url?.absoluteString, "http://127.0.0.1:8000/health")
    }

    func testHealthFailureThrowsInsteadOfCrashing() async {
        // No handler: the stub fails like an unreachable server.
        do {
            _ = try await client.health()
            XCTFail("Expected an error")
        } catch let error as APIError {
            guard case .transport = error else { return XCTFail("Unexpected error \(error)") }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testNonSuccessStatusThrowsHTTPError() async {
        StubURLProtocol.respond(status: 503, json: "{}")
        do {
            _ = try await client.health()
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? APIError, .httpStatus(503))
        }
    }

    func testNearbyBuildsQuery() async throws {
        StubURLProtocol.respond(json: #"{"stores":[]}"#)
        _ = try await client.nearbyStores(latitude: 39.95, longitude: -75.16, limit: 5)
        let url = try XCTUnwrap(StubURLProtocol.requests.first?.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/stores/nearby")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["lat"], "39.95")
        XCTAssertEqual(items["lon"], "-75.16")
        XCTAssertEqual(items["limit"], "5")
    }

    func testSearchEncodesQuery() async throws {
        StubURLProtocol.respond(json: #"{"stores":[]}"#)
        _ = try await client.searchStores(query: "trader joe's & co")
        let url = try XCTUnwrap(StubURLProtocol.requests.first?.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/stores/search")
        XCTAssertEqual(components.queryItems?.first { $0.name == "q" }?.value, "trader joe's & co")
    }

    func testStoreByID() async throws {
        StubURLProtocol.respond(json: """
        {"id":"s1","name":"Acme","address":"1 Main St","latitude":1,"longitude":2,"retailer_name":"Acme"}
        """)
        let store = try await client.store(id: "s1")
        XCTAssertEqual(store.name, "Acme")
        XCTAssertEqual(StubURLProtocol.requests.first?.url?.path, "/stores/s1")
    }

    func testBaseURLWithPathPrefix() throws {
        let prefixed = APIClient(baseURL: URL(string: "https://api.example.com/v1/")!)
        XCTAssertEqual(try prefixed.makeURL(path: "health").absoluteString, "https://api.example.com/v1/health")
    }
}

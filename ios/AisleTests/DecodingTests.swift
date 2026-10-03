import XCTest
@testable import Aisle

final class DecodingTests: XCTestCase {
    func testDecodesHealthOK() throws {
        let health = try JSONDecoder().decode(HealthResponse.self, from: Data(#"{"status":"ok"}"#.utf8))
        XCTAssertEqual(health.status, "ok")
        XCTAssertTrue(health.isOK)
    }

    func testDecodesNearbyStores() throws {
        let json = """
        {"stores":[{"id":"abc","name":"Whole Foods","address":"929 South St","latitude":39.94,
        "longitude":-75.15,"distance_miles":0.1,"retailer_name":"Whole Foods Market"}]}
        """
        let response = try JSONDecoder().decode(StoresResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.stores.count, 1)
        let store = try XCTUnwrap(response.stores.first)
        XCTAssertEqual(store.id, "abc")
        XCTAssertEqual(store.distanceMiles, 0.1)
        XCTAssertEqual(store.retailerName, "Whole Foods Market")
    }

    func testDecodesSearchStoresWithoutDistance() throws {
        let json = """
        {"stores":[{"id":"abc","name":"Whole Foods","address":"929 South St","latitude":39.94,
        "longitude":-75.15,"retailer_name":"Whole Foods Market"}]}
        """
        let response = try JSONDecoder().decode(StoresResponse.self, from: Data(json.utf8))
        XCTAssertNil(response.stores.first?.distanceMiles)
    }
}

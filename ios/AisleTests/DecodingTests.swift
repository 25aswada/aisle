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

final class BackendContractDecodingTests: XCTestCase {
    func testDecodesBackendSearchArrayWithIntegerIDs() throws {
        // Shape returned by the FastAPI backend for `/stores/search`.
        let json = """
        [{"id":2,"retailer_id":1,"name":"Trader Joe's Center City","address":"2121 Market St",
        "latitude":39.95,"longitude":-75.17,"external_place_id":null,"store_number":null,
        "retailer":{"id":1,"name":"Trader Joe's"},"retailer_name":"Trader Joe's"}]
        """
        let response = try JSONDecoder().decode(StoresResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.stores.first?.id, "2")
        XCTAssertEqual(response.stores.first?.retailerName, "Trader Joe's")
    }

    func testDecodesBackendNearbyWithMessage() throws {
        let json = """
        {"stores":[{"id":5,"retailer_id":1,"name":"Costco","address":"201 Allendale Rd",
        "latitude":40.09,"longitude":-75.38,"retailer":{"id":1,"name":"Costco"},
        "retailer_name":"Costco","distance_miles":12.5}],"message":null}
        """
        let response = try JSONDecoder().decode(StoresResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.stores.first?.id, "5")
        XCTAssertEqual(response.stores.first?.distanceMiles, 12.5)
    }

    func testPersistedStoreRoundTrips() throws {
        let data = try JSONEncoder().encode(Fixtures.store)
        XCTAssertEqual(try JSONDecoder().decode(Store.self, from: data), Fixtures.store)
    }
}

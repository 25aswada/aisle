import XCTest
@testable import Aisle

final class ItemSearchDecodingTests: XCTestCase {
    func testDecodesStructuredResult() {
        let result = Fixtures.mapleSyrup
        XCTAssertEqual(result.location.department, "Breakfast/Pantry")
        XCTAssertNil(result.location.aisle)
        XCTAssertEqual(result.location.neighbors, ["pancake mix", "honey", "sweeteners"])
        XCTAssertEqual(result.confidence, .medium)
        XCTAssertEqual(result.source, .fallback)
        XCTAssertEqual(result.availability, .likely)
        XCTAssertEqual(result.category?.name, "Syrups & Sweeteners")
    }

    func testUnknownEnumValuesDegradeSafely() throws {
        let json = Fixtures.mapleSyrupJSON
            .replacingOccurrences(of: #""confidence":"medium""#, with: #""confidence":"certain""#)
            .replacingOccurrences(of: #""source":"fallback""#, with: #""source":"crystal_ball""#)
        let result = try JSONDecoder().decode(ItemSearchResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.confidence, .low)
        XCTAssertEqual(result.source, .fallback)
    }

    func testDecodesNullDepartmentAndCategory() throws {
        let json = """
        {"query":"flux capacitor","item":"flux capacitor","modifiers":[],"quantity":null,"store_id":null,
        "category":null,"location":{"department":null,"aisle":null,"section":null,"neighbors":[]},
        "availability":"unknown","confidence":"low","source":"fallback"}
        """
        let result = try JSONDecoder().decode(ItemSearchResult.self, from: Data(json.utf8))
        XCTAssertNil(result.location.department)
        XCTAssertNil(result.category)
    }
}

final class ItemSearchClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testSearchPostsJSONBodyWithIntegerStoreID() async throws {
        StubURLProtocol.respond(json: Fixtures.mapleSyrupJSON)
        let client = APIClient(baseURL: URL(string: "http://127.0.0.1:8000")!, session: StubURLProtocol.makeSession())
        let result = try await client.searchItem(query: "maple syrup", storeID: "2")
        XCTAssertEqual(result.item, "maple syrup")

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/search")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.bodyData)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["query"] as? String, "maple syrup")
        XCTAssertEqual(json["store_id"] as? Int, 2)
    }
}

@MainActor
final class FindModelTests: XCTestCase {
    func testSearchLoadsResult() async {
        let api = StubAPI()
        let model = FindModel(api: api)
        model.query = "  maple syrup "
        await model.search(storeID: "2")
        XCTAssertEqual(model.phase, .loaded(Fixtures.mapleSyrup))
        XCTAssertEqual(api.itemSearches.first?.0, "maple syrup")
        XCTAssertEqual(api.itemSearches.first?.1, "2")
    }

    func testBlankQueryDoesNotCallAPI() async {
        let api = StubAPI()
        let model = FindModel(api: api)
        model.query = "   "
        await model.search(storeID: "2")
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(api.itemSearches.isEmpty)
    }

    func testMissingStoreShowsSpecificMessage() async {
        let api = StubAPI()
        api.searchItemResult = .failure(APIError.httpStatus(404))
        let model = FindModel(api: api)
        model.query = "milk"
        await model.search(storeID: "999")
        XCTAssertEqual(model.phase, .failed("This store is no longer available. Choose another store."))
    }

    func testTransportErrorIsReported() async {
        let api = StubAPI()
        api.searchItemResult = .failure(APIError.transport("offline"))
        let model = FindModel(api: api)
        model.query = "milk"
        await model.search(storeID: "1")
        guard case .failed = model.phase else { return XCTFail("Expected failure") }
    }
}

extension URLRequest {
    /// URLProtocol receives uploads as a stream; read it back for assertions.
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

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

final class DatabaseLocationDecodingTests: XCTestCase {
    func testDecodesDatabaseLocationWithAisle() throws {
        let json = """
        {"query":"maple syrup","item":"maple syrup","modifiers":[],"quantity":null,"store_id":2,
        "concept":{"id":118,"name":"maple syrup"},
        "category":{"slug":"syrups-sweeteners","name":"Syrups & Sweeteners"},
        "location":{"department":"Breakfast/Pantry","zone_id":17,"aisle":"Aisle 4","section":"Top shelf",
        "neighbors":["pancake mix"]},"availability":"likely","confidence":"high","source":"database"}
        """
        let result = try JSONDecoder().decode(ItemSearchResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.source, .database)
        XCTAssertEqual(result.location.aisle, "Aisle 4")
        XCTAssertEqual(result.location.zoneID, 17)
        XCTAssertEqual(result.concept?.id, 118)
        XCTAssertEqual(result.confidence, .high)
    }

    func testFixtureHasConceptAndZone() {
        XCTAssertEqual(Fixtures.mapleSyrup.concept?.name, "maple syrup")
        XCTAssertEqual(Fixtures.mapleSyrup.location.zoneID, 17)
    }
}


final class ReplyTextTests: XCTestCase {
    private func result(
        department: String?, aisle: String? = nil, zoneID: Int? = 1, confidence: Confidence,
        availability: Availability = .likely, neighbors: [String] = []
    ) -> ItemSearchResult {
        ItemSearchResult(
            searchID: nil, query: "lychee", item: "lychee", modifiers: [], quantity: nil, storeID: 2,
            concept: nil, category: nil,
            location: ItemLocation(department: department, zoneID: zoneID, aisle: aisle, section: nil, neighbors: neighbors),
            availability: availability, confidence: confidence, source: .model, reports: nil
        )
    }

    private func text(_ result: ItemSearchResult, at retailer: String?) -> String {
        String(result.replyText(at: retailer).characters)
    }

    func testLowConfidenceNamesTheStore() {
        let reply = text(result(department: "Flowers & Produce", confidence: .low, neighbors: ["Mangoes"]), at: "Trader Joe's")
        XCTAssertEqual(
            reply,
            "I'm not certain, but Trader Joe's usually keeps lychee in Flowers & Produce. Look near mangoes. If it's not there, ask an employee."
        )
        XCTAssertFalse(reply.contains("stores like this"))
    }

    func testUnlikelyWithoutDepartmentSaysStoreDoesNotCarryIt() {
        let reply = text(result(department: nil, confidence: .low, availability: .unlikely), at: "Trader Joe's")
        XCTAssertEqual(reply, "Trader Joe's typically doesn't carry lychee, but you can ask an employee.")
    }

    func testUnlikelyWithDepartmentPointsThereAndToAnEmployee() {
        let reply = text(result(department: "Frozen", confidence: .low, availability: .unlikely), at: "Costco")
        XCTAssertEqual(reply, "Costco typically doesn't carry lychee. If this one does, check Frozen, or ask an employee.")
    }

    func testUnlikelyCategoryWithoutAZoneIsNotPresentedAsAPlace() {
        // Trader Joe's has no Clothing department; "Clothing" is only the item's category.
        let underwear = result(department: "Clothing", zoneID: nil, confidence: .low, availability: .unlikely, neighbors: ["socks"])
        XCTAssertNil(underwear.placeInStore)
        XCTAssertEqual(text(underwear, at: "Trader Joe's"), "Trader Joe's typically doesn't carry lychee, but you can ask an employee.")
    }

    func testUnknownLocationNamesTheStore() {
        let reply = text(result(department: nil, confidence: .low), at: "Target")
        XCTAssertEqual(reply, "I'm not sure where lychee is at Target yet. Try a more common name, or ask an employee.")
    }

    func testMediumNamesTheStore() {
        XCTAssertEqual(
            text(result(department: "Produce", confidence: .medium), at: "Walmart"),
            "At Walmart, lychee is most likely in Produce."
        )
    }

    func testFallsBackToThisStoreWithoutARetailer() {
        XCTAssertEqual(
            text(result(department: nil, confidence: .low, availability: .unlikely), at: nil),
            "This store typically doesn't carry lychee, but you can ask an employee."
        )
        XCTAssertTrue(text(result(department: "Produce", confidence: .low), at: nil).contains("this store usually keeps"))
    }

    func testNeverMentionsAnAisleThatIsNotOnFile() {
        for confidence in [Confidence.high, .medium, .low] {
            XCTAssertFalse(text(result(department: "Produce", confidence: confidence), at: "Costco").contains("Aisle"))
        }
        XCTAssertTrue(text(result(department: "Produce", aisle: "7", confidence: .high), at: "Costco").contains("Aisle 7"))
    }

    func testSourceLabelsNameTheStore() {
        XCTAssertEqual(LocationSource.model.label(for: "Trader Joe's"), "AI estimate for Trader Joe's")
        XCTAssertEqual(LocationSource.fallback.label(for: "Costco"), "Typical Costco layout")
        XCTAssertEqual(LocationSource.model.label(for: nil), "AI estimate")
    }
}

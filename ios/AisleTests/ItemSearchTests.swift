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
        item: String = "lychee", department: String?, aisle: String? = nil, section: String? = nil,
        zoneID: Int? = 1, category: String? = nil, confidence: Confidence,
        availability: Availability = .likely, source: LocationSource = .model,
        neighbors: [String] = [], reports: ReportCounts? = nil, modifiers: [String] = []
    ) -> ItemSearchResult {
        ItemSearchResult(
            searchID: nil, query: item, item: item, modifiers: modifiers, quantity: nil, storeID: 2,
            concept: nil, category: category.map { ItemCategory(slug: $0.lowercased(), name: $0) },
            location: ItemLocation(department: department, zoneID: zoneID, aisle: aisle, section: section, neighbors: neighbors),
            availability: availability, confidence: confidence, source: source, reports: reports
        )
    }

    private func text(_ result: ItemSearchResult, at retailer: String?) -> String {
        String(result.replyText(at: retailer).characters)
    }

    func testHighConfidenceDescribesAisleShelfNeighboursAndSource() {
        let reply = text(result(
            item: "maple syrup", department: "Pantry & Breakfast", aisle: "14", section: "Left side",
            category: "Syrups & Sweeteners", confidence: .high, source: .database,
            neighbors: ["Pancake mix", "Honey", "Sweeteners", "Jam"]
        ), at: "Costco")
        XCTAssertEqual(
            reply,
            "Found it! Maple syrup is in Aisle 14 · Left side, in the Pantry & Breakfast section at Costco. "
                + "It's usually shelved with the syrups & sweeteners, near pancake mix, honey and sweeteners. "
                + "This comes from Costco's own store data."
        )
    }

    func testMediumExplainsTypicalLayoutAndShopperReports() {
        let reply = text(result(
            item: "cheese", department: "Dairy & Eggs Cooler", category: "Cheese", confidence: .medium,
            source: .fallback, neighbors: ["Butter"], reports: ReportCounts(found: 2, notHere: 1)
        ), at: "Costco")
        XCTAssertEqual(
            reply,
            "At Costco, cheese is most likely in Dairy & Eggs Cooler. Look near butter. "
                + "There's no aisle number on file, so this is based on Costco's typical layout. "
                + "2 shoppers found it here and 1 didn't."
        )
        XCTAssertFalse(reply.contains("shelved with the cheese"))
    }

    func testLowConfidenceNamesTheStoreAndHedges() {
        let reply = text(result(
            department: "Flowers & Produce", category: "Fruit", confidence: .low, neighbors: ["Mangoes"]
        ), at: "Trader Joe's")
        XCTAssertEqual(
            reply,
            "I'm not certain, but Trader Joe's usually keeps lychee in Flowers & Produce. "
                + "It's usually shelved with the fruit, near mangoes. "
                + "This is an AI estimate for Trader Joe's, not a confirmed spot. If it's not there, ask an employee."
        )
        XCTAssertFalse(reply.contains("stores like this"))
    }

    func testModifiersAreCalledOut() {
        let reply = text(result(item: "milk", department: "Dairy", confidence: .medium, source: .database, modifiers: ["Organic", "2%"]), at: "Target")
        XCTAssertTrue(reply.hasSuffix(" You asked for organic and 2%, so check the labels."))
    }

    func testNotHereReportsAskToDoubleCheck() {
        let reply = text(result(department: "Produce", confidence: .medium, source: .observations, reports: ReportCounts(found: 0, notHere: 3)), at: "Target")
        XCTAssertTrue(reply.contains(" Shoppers have confirmed it here. 3 shoppers couldn't find it here, so double-check."))
    }

    func testUnlikelyExplainsWhyAndPointsToAnEmployee() {
        let reply = text(result(
            item: "underwear", department: "Clothing", zoneID: nil, category: "Clothing",
            confidence: .low, availability: .unlikely, neighbors: ["socks"]
        ), at: "Trader Joe's")
        XCTAssertEqual(
            reply,
            "Trader Joe's typically doesn't carry underwear. It's usually sold with clothing, which Trader Joe's "
                + "doesn't normally stock. An employee can tell you for sure, or point you to something similar."
        )
    }

    func testUnlikelyWithARealDepartmentPointsThere() {
        let reply = text(result(department: "Frozen", confidence: .low, availability: .unlikely), at: "Costco")
        XCTAssertEqual(reply, "Costco typically doesn't carry lychee. If this location does have it, check Frozen first, or ask an employee.")
    }

    func testUnlikelyCategoryWithoutAZoneIsNotPresentedAsAPlace() {
        // Trader Joe's has no Clothing department; "Clothing" is only the item's category.
        let underwear = result(department: "Clothing", zoneID: nil, confidence: .low, availability: .unlikely, neighbors: ["socks"])
        XCTAssertNil(underwear.placeInStore)
        XCTAssertFalse(text(underwear, at: "Trader Joe's").contains("check Clothing"))
    }

    func testUnknownLocationNamesTheStoreAndSuggestsTheCategory() {
        XCTAssertEqual(
            text(result(department: nil, category: "Snacks", confidence: .low), at: "Target"),
            "I'm not sure where lychee is at Target yet. It sounds like snacks, so that part of the store is a good "
                + "place to start. Try a more common name, or ask an employee."
        )
    }

    func testFallsBackToThisStoreWithoutARetailer() {
        XCTAssertTrue(text(result(department: nil, confidence: .low, availability: .unlikely), at: nil).hasPrefix("This store typically doesn't carry lychee."))
        XCTAssertTrue(text(result(department: "Produce", confidence: .low), at: nil).contains("this store usually keeps"))
    }

    func testNeverMentionsAnAisleThatIsNotOnFile() {
        for confidence in [Confidence.high, .medium, .low] {
            for source in [LocationSource.database, .observations, .storeLayout, .model, .fallback] {
                let reply = text(result(department: "Produce", confidence: confidence, source: source), at: "Costco")
                XCTAssertFalse(reply.contains("Aisle "), "\(confidence) \(source): \(reply)")
            }
        }
        XCTAssertTrue(text(result(department: "Produce", aisle: "7", confidence: .high), at: "Costco").contains("Aisle 7"))
    }

    func testPrefersTheAIExplanationAndBoldsItsPlace() {
        var withAI = result(department: "Produce", confidence: .low)
        withAI.explanation = "At Costco, lychee is usually in **Produce**, near the mangoes."
        let reply = withAI.reply(at: "Costco")
        XCTAssertEqual(String(reply.characters), "At Costco, lychee is usually in Produce, near the mangoes.")
        let boldRuns = reply.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        XCTAssertEqual(boldRuns.map { String(reply[$0.range].characters) }, ["Produce"])
    }

    func testFallsBackToOwnWordingWithoutAnExplanation() {
        let plain = result(department: "Produce", confidence: .low)
        XCTAssertEqual(String(plain.reply(at: "Costco").characters), text(plain, at: "Costco"))
    }

    func testDecodesExplanationAndLayout() throws {
        let search = try JSONDecoder().decode(ItemSearchResult.self, from: Data("""
        {"query":"lychee","item":"lychee","modifiers":[],"quantity":null,"store_id":1,"concept":null,
         "category":null,"location":{"department":"Produce","zone_id":3,"neighbors":[]},
         "availability":"likely","confidence":"low","source":"model","explanation":"At Costco, try **Produce**."}
        """.utf8))
        XCTAssertEqual(search.explanation, "At Costco, try **Produce**.")

        let layout = try JSONDecoder().decode(StoreLayout.self, from: Data("""
        {"store_id":1,"entrance":{"x":0.5,"y":0},"checkout":null,"approximate":true,
         "zones":[{"id":3,"name":"Produce","x":0.8,"y":0.9,"source":"template"},
                  {"id":4,"name":"Pharmacy","x":null,"y":null,"source":"template"}]}
        """.utf8))
        XCTAssertEqual(layout.entrance, StoreLayout.Point(x: 0.5, y: 0))
        XCTAssertNil(layout.checkout)
        XCTAssertEqual(layout.placedZones.map(\.name), ["Produce"])
    }

    func testSourceLabelsNameTheStore() {
        XCTAssertEqual(LocationSource.model.label(for: "Trader Joe's"), "AI estimate for Trader Joe's")
        XCTAssertEqual(LocationSource.fallback.label(for: "Costco"), "Typical Costco layout")
        XCTAssertEqual(LocationSource.model.label(for: nil), "AI estimate")
    }
}

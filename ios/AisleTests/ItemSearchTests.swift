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

    func testPaymentRequiredBecomesPlusRequired() async throws {
        StubURLProtocol.respond(
            status: 402,
            json: #"{"detail":{"code":"plus_required","feature":"photo_search","message":"Out of free photo searches."}}"#
        )
        let client = APIClient(baseURL: URL(string: "http://127.0.0.1:8000")!, session: StubURLProtocol.makeSession(),
                               authToken: { "session-token" })
        do {
            _ = try await client.identify(photo: Data([0xFF]), note: nil, storeID: nil)
            XCTFail("expected plusRequired")
        } catch let error as APIError {
            XCTAssertEqual(error, .plusRequired(feature: "photo_search", message: "Out of free photo searches."))
        }
        XCTAssertEqual(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
    }

    func testChatPostsTheConversationAndReadsTheReply() async throws {
        StubURLProtocol.respond(json: #"{"reply":"Try the bakery tables.","search":null}"#)
        let client = APIClient(baseURL: URL(string: "http://127.0.0.1:8000")!, session: StubURLProtocol.makeSession())
        let answer = try await client.chat(storeID: "2", messages: [ChatMessage(role: .shopper, content: "cookies")])
        XCTAssertEqual(answer, ChatReply(reply: "Try the bakery tables.", search: nil))

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/chat")
        XCTAssertEqual(request.timeoutInterval, APIClient.replyTimeout)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.bodyData)) as? [String: Any])
        XCTAssertEqual(json["store_id"] as? Int, 2)
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "user", "content": "cookies"]])
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

    func testFollowUpSendsTheWholeConversation() async throws {
        let api = StubAPI()
        let model = FindModel(api: api)
        model.query = "maple syrup"
        await model.search(storeID: "2")

        model.followUp = " I don't see it "
        await model.sendFollowUp(storeID: "2", retailer: "Target")
        XCTAssertEqual(model.turns.map(\.role), [.shopper, .aisle])
        XCTAssertEqual(model.turns.map(\.text), ["I don't see it", "Check the bakery tables by the muffins."])
        XCTAssertEqual(model.followUp, "")

        let (storeID, messages) = try XCTUnwrap(api.chats.first)
        XCTAssertEqual(storeID, "2")
        XCTAssertEqual(messages.map(\.role), ["user", "assistant", "user"])
        XCTAssertEqual(messages.first?.content, "maple syrup")
        XCTAssertEqual(messages.last?.content, "I don't see it")

        model.followUp = "where's the milk"
        await model.sendFollowUp(storeID: "2", retailer: "Target")
        XCTAssertEqual(api.chats.last?.1.count, 5)
    }

    func testFailedFollowUpPutsTheMessageBack() async {
        let api = StubAPI()
        api.chatResult = .success(ChatReply(reply: nil))
        let model = FindModel(api: api)
        model.query = "maple syrup"
        await model.search(storeID: "2")
        model.followUp = "is it organic?"
        await model.sendFollowUp(storeID: "2", retailer: nil)
        XCTAssertTrue(model.turns.isEmpty)
        XCTAssertEqual(model.followUp, "is it organic?")
        XCTAssertNotNil(model.followUpError)
        XCTAssertFalse(model.isReplying)
    }

    func testNewSearchClearsTheConversation() async {
        let api = StubAPI()
        let model = FindModel(api: api)
        model.query = "maple syrup"
        await model.search(storeID: "2")
        model.followUp = "anything else nearby?"
        await model.sendFollowUp(storeID: "2", retailer: nil)
        XCTAssertFalse(model.turns.isEmpty)
        model.clear()
        XCTAssertTrue(model.turns.isEmpty)
        XCTAssertEqual(model.phase, .idle)
    }

    func testPhotoSearchIdentifiesThenSearches() async {
        let api = StubAPI()
        let model = FindModel(api: api)
        let photo = Data([0xFF, 0xD8, 0x01])
        model.photo = photo
        model.query = "the blue one"
        await model.search(storeID: "2")
        XCTAssertEqual(api.identified.first?.0, photo)
        XCTAssertEqual(api.identified.first?.1, "the blue one")
        XCTAssertEqual(api.itemSearches.first?.0, "maple syrup")
        XCTAssertEqual(model.phase, .loaded(Fixtures.mapleSyrup))
        XCTAssertEqual(model.searchPhoto, photo)
        XCTAssertNil(model.photo)
    }

    func testUnrecognisedPhotoKeepsThePhotoToRetry() async {
        let api = StubAPI()
        api.identifyResult = .success(nil)
        let model = FindModel(api: api)
        model.photo = Data([0xFF, 0xD8])
        await model.search(storeID: "2")
        guard case .failed = model.phase else { return XCTFail("Expected failure") }
        XCTAssertNotNil(model.photo)
        XCTAssertTrue(api.itemSearches.isEmpty)
    }

    func testFollowUpPhotoGoesWithTheNewestMessageOnly() async throws {
        let api = StubAPI()
        let model = FindModel(api: api)
        model.query = "maple syrup"
        await model.search(storeID: "2")

        let first = Data([0xFF, 0xD8, 0x01])
        model.photo = first
        await model.sendFollowUp(storeID: "2", retailer: nil)
        XCTAssertEqual(model.turns.first?.photo, first)
        XCTAssertEqual(api.chats.last?.1.last?.image, first.base64EncodedString())

        model.followUp = "and this one?"
        model.photo = Data([0xFF, 0xD8, 0x02])
        await model.sendFollowUp(storeID: "2", retailer: nil)
        let messages = try XCTUnwrap(api.chats.last?.1)
        XCTAssertEqual(messages.compactMap(\.image).count, 1)
        XCTAssertEqual(messages[2].content, "(sent a photo)")
        XCTAssertNil(model.photo)
    }

    func testChatReplyDecodesANewItemsSearch() throws {
        let json = #"{"reply":"Over by the nuts.","search":"# + Fixtures.mapleSyrupJSON + "}"
        let answer = try JSONDecoder().decode(ChatReply.self, from: Data(json.utf8))
        XCTAssertEqual(answer.search, Fixtures.mapleSyrup)
    }

    func testFollowUpForANewItemShowsItsResultAndTakesFeedback() async throws {
        let api = StubAPI()
        let model = FindModel(api: api)
        model.query = "cookies"
        await model.search(storeID: "2")
        await model.confirmFound(storeID: "2")
        XCTAssertEqual(model.feedback, .confirmed)

        let found = try JSONDecoder().decode(
            ItemSearchResult.self,
            from: Data(Fixtures.mapleSyrupJSON.replacingOccurrences(of: "evt-1", with: "follow-up-search").utf8)
        )
        api.chatResult = .success(ChatReply(reply: "Syrup's in the center aisles.", search: found))
        model.followUp = "where's the maple syrup?"
        await model.sendFollowUp(storeID: "2", retailer: nil)

        XCTAssertEqual(model.turns.last?.result, found)
        XCTAssertEqual(model.latestResult, found)
        XCTAssertEqual(model.feedback, .none)
        await model.reportNotHere(storeID: "2")
        XCTAssertEqual(api.feedbackBodies.last?.searchID, "follow-up-search")
    }

    func testConversationalFollowUpKeepsFeedbackOnTheSearch() async {
        let api = StubAPI()
        let model = FindModel(api: api)
        model.query = "maple syrup"
        await model.search(storeID: "2")
        model.followUp = "how much is it?"
        await model.sendFollowUp(storeID: "2", retailer: nil)
        XCTAssertNil(model.turns.last?.result)
        XCTAssertEqual(model.latestResult, model.currentResult)
    }

    func testPhotoSearchOverTheFreeLimitOpensTheUpgrade() async {
        let api = StubAPI()
        api.identifyResult = .failure(APIError.plusRequired(feature: "photo_search", message: "You've used today's 5 free photo searches."))
        let model = FindModel(api: api)
        model.photo = Data([0xFF, 0xD8])
        await model.search(storeID: "2")
        XCTAssertEqual(model.upgradePrompt, "You've used today's 5 free photo searches.")
        XCTAssertNotNil(model.photo, "the photo stays, ready to send after upgrading")
    }

    func testFollowUpOverTheFreeLimitOpensTheUpgrade() async {
        let api = StubAPI()
        let model = FindModel(api: api)
        model.query = "maple syrup"
        await model.search(storeID: "2")
        api.chatResult = .failure(APIError.plusRequired(feature: "follow_up", message: "You've used today's 10 free follow-ups."))
        model.followUp = "and pancakes?"
        await model.sendFollowUp(storeID: "2", retailer: nil)
        XCTAssertEqual(model.upgradePrompt, "You've used today's 10 free follow-ups.")
        XCTAssertEqual(model.followUp, "and pancakes?")
        XCTAssertTrue(model.turns.isEmpty)
    }

    func testFollowUpNeedsAResult() async {
        let api = StubAPI()
        let model = FindModel(api: api)
        model.followUp = "hello"
        await model.sendFollowUp(storeID: "2", retailer: nil)
        XCTAssertTrue(api.chats.isEmpty)
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

final class PhotoPreparationTests: XCTestCase {
    func testDownsizesToJPEG() throws {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 2000)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        }
        let data = try XCTUnwrap(PhotoPreparation.jpeg(from: XCTUnwrap(big.pngData())))
        let image = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(max(image.size.width, image.size.height), 1024, accuracy: 1)
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
        XCTAssertNil(PhotoPreparation.jpeg(from: Data("not an image".utf8)))
    }
}

final class CameraZoomLabelTests: XCTestCase {
    func testLabelsLikeTheSystemCamera() {
        XCTAssertEqual(CameraSheet.zoomLabel(0.5), "0.5")
        XCTAssertEqual(CameraSheet.zoomLabel(1), "1")
        XCTAssertEqual(CameraSheet.zoomLabel(2.04), "2")
        XCTAssertEqual(CameraSheet.zoomLabel(2.36), "2.4")
    }
}

/// Holds searches and chat replies until the test lets them through, so it can start
/// over while one is still on its way.
private final class HeldAPI: AisleAPI, @unchecked Sendable {
    let base = StubAPI()
    var holdSearches = false
    private var held: [CheckedContinuation<Void, Never>] = []
    var heldCount: Int { held.count }

    func release() {
        held.forEach { $0.resume() }
        held = []
    }

    private func hold() async { await withCheckedContinuation { held.append($0) } }

    func searchItem(query: String, storeID: String?) async throws -> ItemSearchResult {
        if holdSearches { await hold() }
        return try await base.searchItem(query: query, storeID: storeID)
    }

    func chat(storeID: String, messages: [ChatMessage]) async throws -> ChatReply {
        await hold()
        return try await base.chat(storeID: storeID, messages: messages)
    }

    func health() async throws -> HealthResponse { try await base.health() }
    func nearbyStores(latitude: Double, longitude: Double, limit: Int?) async throws -> [Store] {
        try await base.nearbyStores(latitude: latitude, longitude: longitude, limit: limit)
    }
    func searchStores(query: String, near: Coordinate?) async throws -> [Store] {
        try await base.searchStores(query: query, near: near)
    }
    func store(id: String) async throws -> Store { try await base.store(id: id) }
    func identify(photo: Data, note: String?, storeID: String?) async throws -> String? {
        try await base.identify(photo: photo, note: note, storeID: storeID)
    }
    func zones(storeID: String) async throws -> [StoreZone] { try await base.zones(storeID: storeID) }
    func storeLayout(storeID: String) async throws -> StoreLayout { try await base.storeLayout(storeID: storeID) }
    func sendFeedback(_ body: FeedbackBody) async throws -> FeedbackReceipt { try await base.sendFeedback(body) }
    func parseList(text: String) async throws -> [ParsedListItem] { try await base.parseList(text: text) }
    func scanList(photo: Data) async throws -> [ParsedListItem] { try await base.scanList(photo: photo) }
    func planRoute(storeID: String, items: [ListItem]) async throws -> RoutePlan {
        try await base.planRoute(storeID: storeID, items: items)
    }
    func planMultiRoute(storeIDs: [String], items: [ListItem]) async throws -> MultiRoutePlan {
        try await base.planMultiRoute(storeIDs: storeIDs, items: items)
    }
    func sendEvents(_ events: [AnalyticsEvent]) async throws { try await base.sendEvents(events) }
}

/// Tapping Find mid-conversation clears it; answers still on their way mustn't bring it back.
@MainActor
final class StartOverTests: XCTestCase {
    private func waitUntilHeld(_ api: HeldAPI) async {
        while api.heldCount == 0 { await Task.yield() }
    }

    func testAReplyArrivingAfterStartingOverIsDropped() async {
        let api = HeldAPI()
        let model = FindModel(api: api)
        model.query = "maple syrup"
        await model.search(storeID: "2")
        model.followUp = "is it organic?"
        let sending = Task { await model.sendFollowUp(storeID: "2", retailer: nil) }
        await waitUntilHeld(api)
        XCTAssertTrue(model.isReplying)

        model.clear()
        api.release()
        await sending.value

        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.turns.isEmpty)
        XCTAssertFalse(model.isReplying)
        XCTAssertEqual(model.followUp, "")
    }

    func testASearchArrivingAfterStartingOverIsDropped() async {
        let api = HeldAPI()
        api.holdSearches = true
        let model = FindModel(api: api)
        model.query = "maple syrup"
        let searching = Task { await model.search(storeID: "2") }
        await waitUntilHeld(api)
        XCTAssertEqual(model.phase, .loading)

        model.clear()
        api.release()
        await searching.value

        XCTAssertEqual(model.phase, .idle)
    }
}

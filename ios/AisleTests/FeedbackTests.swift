import XCTest
@testable import Aisle

@MainActor
final class FeedbackModelTests: XCTestCase {
    private func loadedModel(_ api: StubAPI) async -> FindModel {
        let model = FindModel(api: api)
        model.query = "maple syrup"
        await model.search(storeID: "2")
        return model
    }

    func testFoundItConfirmsSuggestedZone() async {
        let api = StubAPI()
        let model = await loadedModel(api)
        await model.confirmFound(storeID: "2")
        XCTAssertEqual(model.feedback, .confirmed)
        XCTAssertEqual(api.feedbackBodies, [
            FeedbackBody(storeID: 2, item: "maple syrup", verdict: .found, searchID: "evt-1", zoneID: 17, aisle: nil)
        ])
    }

    func testNotHereThenCorrection() async {
        let api = StubAPI()
        let model = await loadedModel(api)
        await model.reportNotHere(storeID: "2")
        XCTAssertEqual(model.feedback, .reportedMissing)
        XCTAssertEqual(api.feedbackBodies.last?.verdict, .notHere)
        XCTAssertEqual(api.feedbackBodies.last?.zoneID, 17)

        await model.submitCorrection(storeID: "2", zone: Fixtures.zones[1], aisle: "  ")
        XCTAssertEqual(model.feedback, .corrected("Frozen"))
        XCTAssertEqual(api.feedbackBodies.last?.zoneID, 21)
        XCTAssertNil(api.feedbackBodies.last?.aisle)
    }

    func testCorrectionKeepsTypedAisle() async {
        let api = StubAPI()
        let model = await loadedModel(api)
        await model.submitCorrection(storeID: "2", zone: Fixtures.zones[1], aisle: " Aisle 9 ")
        XCTAssertEqual(api.feedbackBodies.last?.aisle, "Aisle 9")
    }

    func testFeedbackFailureIsRecoverable() async {
        let api = StubAPI()
        api.feedbackResult = .failure(APIError.transport("offline"))
        let model = await loadedModel(api)
        await model.confirmFound(storeID: "2")
        guard case .failed = model.feedback else { return XCTFail("Expected failure") }
    }

    func testNewSearchResetsFeedback() async {
        let api = StubAPI()
        let model = await loadedModel(api)
        await model.confirmFound(storeID: "2")
        await model.search(storeID: "2")
        XCTAssertEqual(model.feedback, .none)
    }

    func testNoFeedbackWithoutResult() async {
        let api = StubAPI()
        let model = FindModel(api: api)
        await model.confirmFound(storeID: "2")
        XCTAssertTrue(api.feedbackBodies.isEmpty)
    }
}

final class FeedbackClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testFeedbackBodyAndDeviceHeader() async throws {
        StubURLProtocol.respond(json: #"{"id":5,"store_id":2,"verdict":"not_here","zone_id":17,"concept_id":118,"reports":{"found":0,"not_here":1}}"#)
        let client = APIClient(
            baseURL: URL(string: "http://127.0.0.1:8000")!, session: StubURLProtocol.makeSession(), deviceID: "device-abc"
        )
        let receipt = try await client.sendFeedback(
            FeedbackBody(storeID: 2, item: "maple syrup", verdict: .notHere, searchID: "evt-1", zoneID: 17)
        )
        XCTAssertEqual(receipt.reports, ReportCounts(found: 0, notHere: 1))
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/feedback")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Aisle-Device"), "device-abc")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.bodyData)) as? [String: Any])
        XCTAssertEqual(json["verdict"] as? String, "not_here")
        XCTAssertEqual(json["store_id"] as? Int, 2)
        XCTAssertEqual(json["zone_id"] as? Int, 17)
        XCTAssertEqual(json["search_id"] as? String, "evt-1")
    }

    func testDecodesZones() async throws {
        StubURLProtocol.respond(json: #"[{"id":17,"name":"Breakfast/Pantry","aisle_label":null,"source":"template"}]"#)
        let client = APIClient(baseURL: URL(string: "http://127.0.0.1:8000")!, session: StubURLProtocol.makeSession())
        let zones = try await client.zones(storeID: "2")
        XCTAssertEqual(zones, [Fixtures.zones[0]])
        XCTAssertEqual(StubURLProtocol.requests.first?.url?.path, "/stores/2/zones")
    }

    func testDeviceIdentityIsStable() {
        let defaults = UserDefaults(suiteName: "AisleTests.Device")!
        defaults.removePersistentDomain(forName: "AisleTests.Device")
        let first = DeviceIdentity.current(defaults: defaults)
        XCTAssertEqual(DeviceIdentity.current(defaults: defaults), first)
        XCTAssertFalse(first.isEmpty)
    }
}

import XCTest
@testable import Aisle

@MainActor
final class StorePickerModelTests: XCTestCase {
    func testAuthorizedLoadsNearbyOnStart() async {
        let api = StubAPI()
        let model = StorePickerModel(api: api, location: FakeLocationProvider(.authorized))
        await model.start()
        XCTAssertEqual(model.nearby, .loaded([Fixtures.store]))
        XCTAssertEqual(api.nearbyCalls.count, 1)
        XCTAssertEqual(api.nearbyCalls.first?.2, StorePickerModel.nearbyLimit)
    }

    func testDeniedDoesNotCallNearbyAndAllowsSearch() async {
        let api = StubAPI()
        let model = StorePickerModel(api: api, location: FakeLocationProvider(.denied))
        await model.start()
        XCTAssertTrue(model.isLocationBlocked)
        XCTAssertEqual(model.nearby, .idle)
        XCTAssertTrue(api.nearbyCalls.isEmpty)

        await model.search("target")
        XCTAssertEqual(api.searchQueries, ["target"])
        XCTAssertEqual(model.searchResults, .loaded([Fixtures.store]))
    }

    func testRestrictedIsTreatedAsBlocked() async {
        let model = StorePickerModel(api: StubAPI(), location: FakeLocationProvider(.restricted))
        await model.start()
        XCTAssertTrue(model.isLocationBlocked)
    }

    func testStartNeverPromptsForPermission() async {
        let location = FakeLocationProvider(.notDetermined, afterPrompt: .authorized)
        let model = StorePickerModel(api: StubAPI(), location: location)
        await model.start()
        XCTAssertEqual(location.promptCount, 0)
        XCTAssertEqual(model.locationAuthorization, .notDetermined)
    }

    func testRequestingLocationThenGrantedLoadsNearby() async {
        let api = StubAPI()
        let location = FakeLocationProvider(.notDetermined, afterPrompt: .authorized)
        let model = StorePickerModel(api: api, location: location)
        await model.requestLocationAndLoadNearby()
        XCTAssertEqual(location.promptCount, 1)
        XCTAssertEqual(model.nearby, .loaded([Fixtures.store]))
    }

    func testRequestingLocationThenDeniedFallsBackToSearch() async {
        let api = StubAPI()
        let model = StorePickerModel(api: api, location: FakeLocationProvider(.notDetermined, afterPrompt: .denied))
        await model.requestLocationAndLoadNearby()
        XCTAssertTrue(model.isLocationBlocked)
        XCTAssertTrue(api.nearbyCalls.isEmpty)
    }

    func testLocationFixFailureShowsMessage() async {
        let location = FakeLocationProvider(.authorized)
        location.coordinate = nil
        let model = StorePickerModel(api: StubAPI(), location: location)
        await model.loadNearby()
        guard case .failed = model.nearby else { return XCTFail("Expected failure, got \(model.nearby)") }
    }

    func testSearchErrorIsReported() async {
        let api = StubAPI()
        api.searchResult = .failure(APIError.httpStatus(500))
        let model = StorePickerModel(api: api, location: FakeLocationProvider(.denied))
        await model.search("x")
        guard case .failed = model.searchResults else { return XCTFail("Expected failure") }
    }

    func testBlankSearchResetsWithoutCallingAPI() async {
        let api = StubAPI()
        let model = StorePickerModel(api: api, location: FakeLocationProvider(.denied))
        await model.search("   ")
        XCTAssertEqual(model.searchResults, .idle)
        XCTAssertTrue(api.searchQueries.isEmpty)
    }
}

@MainActor
final class HealthMonitorTests: XCTestCase {
    func testOK() async {
        let monitor = HealthMonitor(api: StubAPI())
        await monitor.check()
        XCTAssertEqual(monitor.status, .ok)
    }

    func testFailureIsQuiet() async {
        let api = StubAPI()
        api.healthResult = .failure(APIError.transport("offline"))
        let monitor = HealthMonitor(api: api)
        await monitor.check()
        XCTAssertEqual(monitor.status, .unreachable)
    }
}

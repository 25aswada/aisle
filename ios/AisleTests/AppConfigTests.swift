import XCTest
@testable import Aisle

final class AppConfigTests: XCTestCase {
    func testDefaultsToLocalhost() {
        let config = AppConfig(environment: [:], infoDictionary: [:])
        XCTAssertEqual(config.apiBaseURL.absoluteString, "http://127.0.0.1:8000")
    }

    func testReadsInfoPlist() {
        let config = AppConfig(environment: [:], infoDictionary: ["AisleAPIBaseURL": "http://10.0.0.5:9000"])
        XCTAssertEqual(config.apiBaseURL.absoluteString, "http://10.0.0.5:9000")
    }

    func testEnvironmentOverridesInfoPlist() {
        let config = AppConfig(
            environment: ["AISLE_API_BASE_URL": "http://192.168.1.2:8000"],
            infoDictionary: ["AisleAPIBaseURL": "http://10.0.0.5:9000"]
        )
        XCTAssertEqual(config.apiBaseURL.absoluteString, "http://192.168.1.2:8000")
    }

    func testIgnoresUnexpandedBuildSetting() {
        let config = AppConfig(environment: [:], infoDictionary: ["AisleAPIBaseURL": "$(AISLE_API_BASE_URL)"])
        XCTAssertEqual(config.apiBaseURL, AppConfig.defaultAPIBaseURL)
    }

    func testAppBundleHasLocationExplanation() {
        let text = Bundle(for: StoreSelection.self).object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") as? String
        XCTAssertFalse((text ?? "").isEmpty)
    }
}

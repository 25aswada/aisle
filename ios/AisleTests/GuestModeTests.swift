import XCTest
@testable import Aisle

final class GuestModeTests: XCTestCase {
    private let morning = Date(timeIntervalSince1970: 1_791_100_800)

    func testTheNudgeComesAfterTheSecondSearchOnceADay() {
        let defaults = UserDefaults.fresh("GuestModeTests.Nudge")
        XCTAssertFalse(GuestNudge.recordSearch(now: morning, defaults: defaults))
        XCTAssertTrue(GuestNudge.recordSearch(now: morning.addingTimeInterval(60), defaults: defaults))
        XCTAssertFalse(GuestNudge.recordSearch(now: morning.addingTimeInterval(120), defaults: defaults))
        // A new day counts from zero again.
        let tomorrow = morning.addingTimeInterval(86_400)
        XCTAssertFalse(GuestNudge.recordSearch(now: tomorrow, defaults: defaults))
        XCTAssertTrue(GuestNudge.recordSearch(now: tomorrow, defaults: defaults))
    }

    func testNoNudgeOnADayTheGuestWasAlreadyAsked() {
        let defaults = UserDefaults.fresh("GuestModeTests.Asked")
        GuestNudge.markShown(now: morning, defaults: defaults)
        XCTAssertFalse(GuestNudge.recordSearch(now: morning, defaults: defaults))
        XCTAssertFalse(GuestNudge.recordSearch(now: morning, defaults: defaults))
    }

    func testEachReasonLeadsWithItsOwnBenefit() {
        XCTAssertEqual(SignUpReason.photoSearch.benefits.first?.symbol, "camera")
        XCTAssertEqual(SignUpReason.joinList.benefits.first?.symbol, "person.2")
        XCTAssertEqual(SignUpReason.plus.benefits.first?.symbol, "sparkles")
        XCTAssertEqual(SignUpReason.searchLimit.benefits.first?.symbol, "magnifyingglass")
        for reason in [SignUpReason.photoSearch, .plus, .you] {
            XCTAssertEqual(Set(reason.benefits.map(\.text)), Set(SignUpReason.allBenefits.map(\.text)))
        }
    }
}

import XCTest
@testable import X6Core

final class RidingSessionTests: XCTestCase {
    func testOpeningStartsOnceAndReopeningExtendsDeadline() {
        var policy = RidingSessionPolicy()
        XCTAssertEqual(policy.opened(enabled: true, at: 0), .start)
        XCTAssertEqual(policy.remaining(at: 0), RidingSessionPolicy.maximumDuration)
        XCTAssertEqual(policy.opened(enabled: true, at: 3_600), .none)
        XCTAssertEqual(policy.remaining(at: 3_600), RidingSessionPolicy.maximumDuration)
        XCTAssertEqual(policy.check(at: RidingSessionPolicy.maximumDuration + 1), .none)
    }

    func testFourHourCapEndsSessionUntilNextOpen() {
        var policy = RidingSessionPolicy()
        _ = policy.opened(enabled: true, at: 100)
        XCTAssertEqual(policy.check(at: 100 + RidingSessionPolicy.maximumDuration - 1), .none)
        XCTAssertEqual(policy.check(at: 100 + RidingSessionPolicy.maximumDuration), .stop)
        XCTAssertFalse(policy.wanted)
        XCTAssertNil(policy.remaining(at: 100 + RidingSessionPolicy.maximumDuration))
        XCTAssertEqual(policy.check(at: 100 + RidingSessionPolicy.maximumDuration + 10), .none)
        XCTAssertEqual(policy.opened(enabled: true, at: 20_000), .start)
    }

    func testManualEndStaysEndedWhileFrontmostAndRestartsOnNextOpen() {
        var policy = RidingSessionPolicy()
        _ = policy.opened(enabled: true, at: 0)
        XCTAssertEqual(policy.userEnded(), .stop)
        XCTAssertEqual(policy.userEnded(), .none)
        XCTAssertEqual(policy.check(at: 99_999), .none)
        XCTAssertEqual(policy.opened(enabled: true, at: 50), .start)
    }

    func testManualStartWorksWithAutomaticSettingOff() {
        var policy = RidingSessionPolicy()
        XCTAssertEqual(policy.opened(enabled: false, at: 0), .none)
        XCTAssertEqual(policy.userStarted(at: 10), .start)
        XCTAssertEqual(policy.userStarted(at: 20), .none)
        XCTAssertEqual(policy.remaining(at: 20), RidingSessionPolicy.maximumDuration)
    }

    func testManualSessionSurvivesReopenWithAutomaticStartOff() {
        var policy = RidingSessionPolicy()
        _ = policy.userStarted(at: 1)
        XCTAssertEqual(policy.opened(enabled: false, at: 2), .none)
        XCTAssertTrue(policy.wanted)
        XCTAssertEqual(policy.remaining(at: 2), RidingSessionPolicy.maximumDuration)
    }

    func testPollingCadence() {
        XCTAssertEqual(StatusPollingSchedule.interval(active: true, frontmost: true, riding: false), 3)
        XCTAssertEqual(StatusPollingSchedule.interval(active: false, frontmost: true, riding: false), 10)
        XCTAssertEqual(StatusPollingSchedule.interval(active: false, frontmost: false, riding: true), 10)
        XCTAssertNil(StatusPollingSchedule.interval(active: false, frontmost: false, riding: false))
    }
}

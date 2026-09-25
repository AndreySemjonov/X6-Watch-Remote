import XCTest
@testable import X6Core

final class CameraNoticeTests: XCTestCase {
    func testConnectionNoticesRequireAnActualTransition() {
        var tracker = CameraNoticeTracker()
        XCTAssertNil(tracker.connectionChanged(false))
        XCTAssertEqual(tracker.connectionChanged(true), .connected)
        XCTAssertNil(tracker.connectionChanged(true))
        XCTAssertEqual(tracker.observed(.recording), .recording)
        XCTAssertEqual(tracker.connectionChanged(false), .disconnected)
        XCTAssertNil(tracker.connectionChanged(false))
        XCTAssertNil(tracker.observed(.stopped))
        XCTAssertEqual(tracker.connectionChanged(true), .connected)
        XCTAssertEqual(tracker.observed(.recording), .recording)
    }

    func testRepeatedPollsDoNotGenerateRepeatedNotices() {
        var tracker = CameraNoticeTracker()
        _ = tracker.connectionChanged(true)
        XCTAssertEqual(tracker.observed(.stopped), .stopped)
        for _ in 0..<20 { XCTAssertNil(tracker.observed(.stopped)) }
        XCTAssertEqual(tracker.observed(.recording), .recording)
        XCTAssertNil(tracker.observed(.recording))
        XCTAssertEqual(tracker.observed(.unknown), .unknown)
        XCTAssertNil(tracker.observed(.unknown))
    }

    func testCommandConfirmationDoesNotDuplicateNextPoll() {
        var tracker = CameraNoticeTracker()
        _ = tracker.connectionChanged(true)
        XCTAssertEqual(tracker.confirmed(.recording), .recording)
        XCTAssertNil(tracker.observed(.recording))
        XCTAssertEqual(tracker.confirmed(.stopped), .stopped)
        XCTAssertNil(tracker.observed(.stopped))
    }

    func testQueuedStopNeverClaimsCameraStopped() {
        var tracker = CameraNoticeTracker()
        XCTAssertEqual(tracker.confirmed(.stopQueued), .stopQueued)
        XCTAssertNil(tracker.observed(.stopped))
        _ = tracker.connectionChanged(true)
        XCTAssertEqual(tracker.observed(.recording), .recording)
        XCTAssertEqual(tracker.confirmed(.stopped), .stopped)
    }
}

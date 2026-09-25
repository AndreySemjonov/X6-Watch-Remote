import XCTest
@testable import X6Core

final class RecordingPresentationTests: XCTestCase {
    func testKnownStatesSelectExplicitCommands() {
        XCTAssertEqual(RecordingControl(state: .stopped, ready: true, busy: false, pendingStop: false).action, .start)
        XCTAssertEqual(RecordingControl(state: .recording, ready: true, busy: false, pendingStop: false).action, .stop)
    }

    func testUnknownAndDisconnectedNeverStart() {
        XCTAssertEqual(RecordingControl(state: .unknown, ready: true, busy: false, pendingStop: false).action, .status)
        for state: RecordingState in [.stopped, .recording, .unknown] {
            let control = RecordingControl(state: state, ready: false, busy: false, pendingStop: false)
            XCTAssertEqual(control, .disconnected)
            XCTAssertEqual(control.action, .stop)
        }
    }

    func testPendingStopAndBusyCannotAcceptAnotherCommand() {
        for ready in [false, true] {
            for busy in [false, true] {
                let control = RecordingControl(state: .stopped, ready: ready, busy: busy, pendingStop: true)
                XCTAssertEqual(control, .stopQueued)
                XCTAssertNil(control.action)
            }
            XCTAssertNil(RecordingControl(state: .stopped, ready: ready, busy: true, pendingStop: false).action)
        }
    }

    func testVisibleAppAndTemporaryInterruptionStayQuiet() {
        var policy = StatusNotificationPolicy()
        policy.sceneChanged(.active)
        XCTAssertFalse(policy.allowsStatusNotifications)
        policy.sceneChanged(.inactive)
        XCTAssertFalse(policy.allowsStatusNotifications)
        policy.sceneChanged(.background)
        XCTAssertTrue(policy.allowsStatusNotifications)
    }

    func testForegroundCommandStaysQuietUntilCompletionEvenIfAppLeaves() {
        var policy = StatusNotificationPolicy()
        policy.sceneChanged(.active)
        policy.beginCommand()
        policy.sceneChanged(.background)
        XCTAssertFalse(policy.allowsStatusNotifications)
        policy.endCommand()
        XCTAssertTrue(policy.allowsStatusNotifications)
    }

    func testBackgroundIntentCanNotifyButOpeningAppSuppressesIt() {
        var policy = StatusNotificationPolicy()
        policy.sceneChanged(.inactive)
        policy.beginCommand()
        XCTAssertTrue(policy.allowsStatusNotifications)
        policy.sceneChanged(.active)
        XCTAssertFalse(policy.allowsStatusNotifications)
        policy.endCommand()
        XCTAssertFalse(policy.allowsStatusNotifications)
    }
}

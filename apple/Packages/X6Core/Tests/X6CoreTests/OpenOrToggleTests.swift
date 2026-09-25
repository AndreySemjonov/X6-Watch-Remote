import Foundation
import XCTest
@testable import X6Core

final class OpenOrToggleTests: XCTestCase {
    func testColdLaunchNeverPromotesFastConnectionToCapture() {
        var gate = OpenOrToggleGate()
        let connection = UUID()
        gate.sceneChanged(active: true, connection: connection)
        XCTAssertNil(gate.takeConnection(current: connection))
        XCTAssertEqual(gate.takeConnection(current: connection), connection)
    }

    @MainActor func testDisconnectedActivationThenFastReconnectNeedsSecondPress() async throws {
        var gate = OpenOrToggleGate()
        gate.sceneChanged(active: true, connection: nil)
        _ = gate.takeConnection(current: nil)
        gate.sceneChanged(active: false, connection: nil)
        gate.sceneChanged(active: true, connection: nil)
        // Connection arrives during opening, before perform() gets runtime.
        let connection = UUID()
        let link = FakeLink()
        let session = RecordingSession(link: link, delay: {})
        XCTAssertNil(gate.takeConnection(current: connection))
        XCTAssertTrue(link.calls.isEmpty)
        XCTAssertFalse(session.pendingStop)
        // The next physical press, on the established connection, may toggle.
        XCTAssertEqual(gate.takeConnection(current: connection), connection)
        let result = try await session.toggleConnectedOnly(isCurrentConnection: { true })
        XCTAssertEqual(result, .recording)
        XCTAssertEqual(link.calls, [.status, .start, .status])
    }

    @MainActor func testExistingConnectionSurvivesReactivationAndStopsUsingFreshState() async throws {
        var gate = OpenOrToggleGate()
        let connection = UUID()
        gate.sceneChanged(active: true, connection: nil)
        _ = gate.takeConnection(current: nil)
        gate.sceneChanged(active: false, connection: connection)
        gate.sceneChanged(active: true, connection: connection)
        XCTAssertEqual(gate.takeConnection(current: connection), connection)
        let link = FakeLink(); link.recording = true
        let session = RecordingSession(link: link, delay: {})
        let result = try await session.toggleConnectedOnly(isCurrentConnection: { true })
        XCTAssertEqual(result, .stopped)
        XCTAssertEqual(link.calls, [.status, .stop, .status])
    }

    func testConnectionReplacedDuringOpeningCannotToggle() {
        var gate = OpenOrToggleGate()
        gate.sceneChanged(active: true, connection: nil)
        _ = gate.takeConnection(current: nil)
        let old = UUID(), new = UUID()
        gate.sceneChanged(active: false, connection: old)
        gate.sceneChanged(active: true, connection: old)
        XCTAssertNil(gate.takeConnection(current: new))
        XCTAssertEqual(gate.takeConnection(current: new), new)
    }

    @MainActor func testDisconnectedPressDoesNotQueueStopAndLaterConnectionDoesNotCapture() async throws {
        let link = FakeLink(); link.isReady = false; link.recording = true
        let session = RecordingSession(link: link, delay: {})
        let result = try await session.toggleConnectedOnly(isCurrentConnection: { true })
        XCTAssertNil(result)
        XCTAssertFalse(session.pendingStop)
        XCTAssertEqual(link.reconnects, 1)
        XCTAssertTrue(link.calls.isEmpty)
        link.isReady = true
        try await session.connectionReady()
        XCTAssertEqual(link.calls, [.status])
        XCTAssertTrue(link.recording)
    }

    @MainActor func testConnectionChangesDuringStatusReadNoCaptureIsSent() async throws {
        let link = FakeLink()
        let session = RecordingSession(link: link, delay: {})
        var sameConnection = true
        link.queryHook = { sameConnection = false }
        let result = try await session.toggleConnectedOnly(isCurrentConnection: { sameConnection })
        XCTAssertNil(result)
        XCTAssertEqual(link.calls, [.status])
        XCTAssertFalse(session.pendingStop)
        XCTAssertFalse(session.busy)
    }

    @MainActor func testUnknownCameraStateStillRefusesCapture() async {
        let link = FakeLink(); link.unknown = true
        let session = RecordingSession(link: link, delay: {})
        do {
            _ = try await session.toggleConnectedOnly(isCurrentConnection: { true })
            XCTFail("Unknown camera status must not become START")
        } catch { XCTAssertEqual(error as? SessionError, .unknownState) }
        XCTAssertEqual(link.calls, [.status])
        XCTAssertFalse(session.pendingStop)
    }
}

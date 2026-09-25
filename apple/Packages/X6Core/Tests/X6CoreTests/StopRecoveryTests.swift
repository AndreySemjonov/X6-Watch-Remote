import XCTest
@testable import X6Core

/// Models an observed trace: STOP replies successfully, but the next nine
/// status replies still say recording. The later idle reply is a test scenario,
/// not a claim that it was captured from a camera.
@MainActor private final class DelayedStopLink: CameraLink {
    var isReady = true
    var physicallyRecording = true
    var staleReplies = 9
    var ignoreStop = false
    var calls: [CameraCommand] = []
    func requestReconnect() {}
    func request(_ command: CameraCommand) async throws -> [UInt8] {
        calls.append(command)
        if command == .stop { if !ignoreStop { physicallyRecording = false }; return [] }
        if command == .status {
            let recording = physicallyRecording || staleReplies > 0
            if !physicallyRecording { staleReplies -= 1 }
            return [0x0a, 6, 8, recording ? 1 : 0, 0x10, 0, 0x50, 0]
        }
        XCTFail("Recovery must not START or send unrelated commands")
        return []
    }
}

final class StopRecoveryTests: XCTestCase {
    @MainActor func testStopCanConfirmAfterNineStaleRepliesWithoutSendingStopAgain() async throws {
        let link = DelayedStopLink()
        var time = 0.0
        let session = RecordingSession(link: link, now: { time }, delay: { time += 0.5 })
        let result = try await session.stop()
        XCTAssertEqual(result, .stopped)
        XCTAssertFalse(link.physicallyRecording)
        XCTAssertEqual(link.calls.filter { $0 == .stop }.count, 1)
        XCTAssertFalse(link.calls.contains(.start))
        XCTAssertFalse(session.busy)
    }

    @MainActor func testAcknowledgedStopWithoutIdleEvidenceStillFailsWithinWindow() async {
        let link = DelayedStopLink(); link.ignoreStop = true
        var time = 0.0
        let session = RecordingSession(link: link, now: { time }, delay: { time += 0.5 })
        var confirmations: [ControlResult] = []
        session.confirmed = { confirmations.append($0) }
        do { _ = try await session.stop(); XCTFail("An ACK alone must never confirm STOP") }
        catch { XCTAssertEqual(error as? SessionError, .notConfirmed) }
        XCTAssertEqual(time, RecordingSession.stopConfirmationWindow)
        XCTAssertEqual(session.captureStage, "STOP confirmation")
        XCTAssertTrue(link.physicallyRecording)
        XCTAssertEqual(session.state, .unknown)
        XCTAssertTrue(confirmations.isEmpty)
        XCTAssertEqual(link.calls.filter { $0 == .stop }.count, 1)
        XCTAssertFalse(session.busy)
    }

    @MainActor func testStopConfirmsAfterFourteenSecondsOfStaleRecordingStatus() async throws {
        let link = DelayedStopLink(); link.staleReplies = 28
        var time = 0.0
        let session = RecordingSession(link: link, now: { time }, delay: { time += 0.5 })
        session.clearCaptureStage()
        let result = try await session.stop()
        XCTAssertEqual(result, .stopped)
        XCTAssertEqual(session.captureStage, "STOP confirmed")
        XCTAssertEqual(link.calls.filter { $0 == .stop }.count, 1)
    }

    func testCaptureRepliesGetLongerTimeoutThanStatusReads() {
        XCTAssertEqual(CommandTimeouts.reply(for: .stop), 8)
        XCTAssertEqual(CommandTimeouts.reply(for: .start), 8)
        XCTAssertEqual(CommandTimeouts.reply(for: .status), 4)
        XCTAssertEqual(CommandTimeouts.reply(for: .telemetry), 4)
        XCTAssertGreaterThan(CommandTimeouts.stopCommand,
                             CommandTimeouts.statusReply + CommandTimeouts.captureReply)
    }

    @MainActor func testCommandDeadlineWinsOverLongerStopConfirmationWindow() async {
        let link = DelayedStopLink()
        let session = RecordingSession(link: link, delay: {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        })
        do {
            _ = try await CommandDeadline.run(seconds: 0.05) { try await session.stop() }
            XCTFail("Confirmation must obey the enclosing deadline")
        } catch {}
        XCTAssertFalse(link.physicallyRecording)
        XCTAssertEqual(session.state, .unknown)
        XCTAssertEqual(link.calls, [.status, .stop])
        XCTAssertFalse(session.busy)
    }

    @MainActor func testCommandTraceIncludesDecodedAndRawStatusEvidence() async throws {
        let link = DelayedStopLink(); link.staleReplies = 0
        let session = RecordingSession(link: link, delay: {})
        var events: [String] = []
        session.diagnostic = { events.append($0) }
        _ = try await session.stop()
        XCTAssertTrue(events.contains { $0.contains("raw_state=1") && $0.contains("body=0a06080110005000") })
        XCTAssertTrue(events.contains { $0.contains("raw_state=0") && $0.contains("observed=stopped") })
    }
}

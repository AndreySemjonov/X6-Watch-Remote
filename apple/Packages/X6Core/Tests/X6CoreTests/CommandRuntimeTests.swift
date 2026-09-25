import Foundation
import XCTest
@testable import X6Core

final class CommandRuntimeTests: XCTestCase {
    @MainActor func testFastCommandCompletesAndCancelsDeadlineTimer() async throws {
        let link = FakeLink()
        let session = RecordingSession(link: link, delay: {})
        let result = try await CommandDeadline.run(seconds: 1) { try await session.start() }
        XCTAssertEqual(result, .recording)
        XCTAssertFalse(session.busy)
        XCTAssertEqual(link.calls, [.status, .start, .status])
    }

    @MainActor func testDeadlineCancelsBlockedReadReleasesSlotAndDoesNotStart() async throws {
        let link = FakeLink()
        link.waitForQuery = { try? await Task.sleep(nanoseconds: 60_000_000_000) }
        let session = RecordingSession(link: link, delay: {})
        do {
            _ = try await CommandDeadline.run(seconds: 0.05) { try await session.start() }
            XCTFail("The blocked request must finish as an error")
        } catch { XCTAssertEqual(error as? SessionError, .deadlineExceeded) }
        XCTAssertFalse(session.busy)
        XCTAssertEqual(link.calls, [.status])
        link.waitForQuery = nil
        let next = try await session.start()
        XCTAssertEqual(next, .recording, "An expired command must not hold the slot")
    }

    @MainActor func testDeadlineAfterStopDoesNotReplayOrClaimUnconfirmedSuccess() async {
        let link = FakeLink(); link.recording = true
        link.waitForQuery = {
            if !link.recording { try? await Task.sleep(nanoseconds: 60_000_000_000) }
        }
        let session = RecordingSession(link: link, delay: {})
        var confirmations = 0; session.confirmed = { _ in confirmations += 1 }
        do {
            _ = try await CommandDeadline.run(seconds: 0.05) { try await session.stop() }
            XCTFail("Unconfirmed STOP must fail even if physically applied")
        } catch {}
        XCTAssertFalse(link.recording)
        XCTAssertFalse(session.busy)
        XCTAssertEqual(session.state, .unknown)
        XCTAssertEqual(confirmations, 0)
        XCTAssertEqual(link.calls, [.status, .stop, .status])
    }

    @MainActor func testExpiredContextPreventsLateStartWithoutTimeoutTask() async {
        let link = FakeLink()
        let session = RecordingSession(link: link, delay: {})
        // Models resumption after a runtime gap, before a timeout task is scheduled.
        await CommandDeadline.$expiresAt.withValue(ProcessInfo.processInfo.systemUptime - 1) {
            do { _ = try await session.start(); XCTFail("No late capture") }
            catch { XCTAssertEqual(error as? SessionError, .deadlineExceeded) }
        }
        XCTAssertTrue(link.calls.isEmpty)
        XCTAssertFalse(session.busy)
    }

    @MainActor func testParentCancellationDoesNotBeginCapture() async {
        let link = FakeLink()
        let session = RecordingSession(link: link, delay: {})
        let task = Task {
            try await CommandDeadline.run(seconds: 1) { try await session.start() }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must propagate") } catch {}
        XCTAssertTrue(link.calls.isEmpty)
        XCTAssertFalse(session.busy)
    }

    func testAutomaticFailureBurstGetsOneAlertPerThirtySeconds() {
        var gate = AutomaticFeedbackGate()
        // The captured home/Mac failure pattern contains multiple recovery errors
        // within seconds. Each used to request another haptic and failed notice.
        let alertTimes = [0.0, 0.1, 0.3, 1, 2, 3, 5, 8, 29, 30, 30.1]
            .filter { gate.allow(at: $0) }
        XCTAssertEqual(alertTimes, [0, 30])
    }

    func testCompletedCommandSurvivesLaterReconnectTraffic() {
        var trace = CommandTrace()
        XCTAssertTrue(trace.begin(context: ["ready"]))
        trace.append("user_action=stop")
        trace.append("request timeout")
        trace.append("user_action_finished=stop")
        trace.finish()
        let saved = trace.report
        for _ in 0..<200 { trace.append("reconnecting") }
        XCTAssertEqual(trace.report, saved)
        XCTAssertTrue(saved.contains("request timeout"))
        XCTAssertEqual(CommandTrace(lastReport: saved).report, saved)
    }

    func testFailedReportSurvivesLaterSuccessfulCommands() {
        var trace = CommandTrace()
        trace.begin(context: [])
        trace.append("capture_unconfirmed desired=stopped")
        trace.finish(failureSummary: "STOP failed")
        XCTAssertTrue(trace.lastFailureReport.hasPrefix("STOP failed\n\n"))
        XCTAssertTrue(trace.lastFailureReport.contains("capture_unconfirmed"))
        let failed = trace.lastFailureReport
        trace.begin(context: [])
        trace.append("confirmed=stopped")
        trace.finish()
        XCTAssertEqual(trace.lastFailureReport, failed)
        XCTAssertTrue(trace.report.contains("confirmed=stopped"))
        XCTAssertEqual(CommandTrace(lastFailureReport: failed).lastFailureReport, failed)
    }

    func testRejectedCommandRecordsFailureWithoutEndingActiveTrace() {
        var trace = CommandTrace()
        trace.begin(context: [])
        trace.append("capture_requested desired=stopped")
        trace.recordFailure("toggle rejected: busy", context: ["a", "b"])
        XCTAssertEqual(trace.lastFailureReport, "toggle rejected: busy\n\na\nb")
        XCTAssertTrue(trace.isActive)
        trace.finish()
        XCTAssertTrue(trace.report.contains("capture_requested"))
        XCTAssertEqual(trace.lastFailureReport, "toggle rejected: busy\n\na\nb")
    }

    func testLongCommandPreservesBeginningAndFailureWithBoundedStorage() {
        var trace = CommandTrace(limit: 10)
        trace.begin(context: [])
        trace.append("user_action=toggle")
        for i in 0..<200 { trace.append("event \(i)") }
        trace.append("deadline_exceeded")
        XCTAssertFalse(trace.begin(context: ["another action"]), "Do not replace an active report")
        trace.finish()
        XCTAssertTrue(trace.report.hasPrefix("user_action=toggle"))
        XCTAssertTrue(trace.report.hasSuffix("deadline_exceeded"))
        XCTAssertTrue(trace.report.contains("intermediate events omitted"))
        XCTAssertLessThanOrEqual(trace.report.split(separator: "\n").count, 11)
    }
}

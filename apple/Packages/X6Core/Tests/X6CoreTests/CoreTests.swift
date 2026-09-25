import XCTest
@testable import X6Core

final class CoreTests: XCTestCase {
    let idle = "55434432010c040111000000c800020100008000000a060800100050000b3f9090"
    func testCapturedIdleAndEverySplit() throws {
        let bytes = try [UInt8](hex: idle)
        for split in 0...bytes.count {
            var decoder = UCD2Decoder()
            let messages = try decoder.feed(Array(bytes.prefix(split))) + decoder.feed(Array(bytes.dropFirst(split)))
            XCTAssertEqual(messages.count, 1)
            XCTAssertEqual(messages[0].code, 200)
            XCTAssertEqual(try CaptureStatus.decodeResponse(messages[0].body).recording, .stopped)
        }
    }
    func testBadCRCAndRecovery() throws {
        var bytes = try [UInt8](hex: idle); bytes[24] ^= 1
        var decoder = UCD2Decoder()
        XCTAssertThrowsError(try decoder.feed(bytes))
        XCTAssertEqual(try decoder.feed([UInt8](hex: idle)).count, 1)
    }
    func testCoalescedPackets() throws {
        var decoder = UCD2Decoder()
        let bytes = try [UInt8](hex: idle)
        XCTAssertEqual(try decoder.feed(bytes + bytes).count, 2)
    }
    func testOversizedPayload() throws {
        var bytes = try [UInt8](hex: idle)
        bytes.replaceSubrange(8..<12, with: [255, 255, 255, 255])
        var decoder = UCD2Decoder()
        XCTAssertThrowsError(try decoder.feed(bytes))
    }
    func testInvalidIdentifiers() {
        XCTAssertThrowsError(try UCD2.encode(.start, id: 0, sequence: 0))
        XCTAssertThrowsError(try UCD2.encode(.stop, id: 0x40000000, sequence: 0))
    }
    func testCaptureAndUnknownStates() throws {
        let status = try CaptureStatus.decodeResponse([UInt8](hex: "0a06080110085000"))
        XCTAssertEqual(status.recording, .recording); XCTAssertEqual(status.elapsed, 8)
        XCTAssertEqual(try CaptureStatus.decodeResponse([UInt8](hex: "0a02084f")).recording, .unknown)
        XCTAssertEqual(try CaptureStatus.decodeResponse([UInt8](hex: "0a00")).recording, .unknown)
        XCTAssertThrowsError(try CaptureStatus.decodeResponse([]))
        XCTAssertThrowsError(try CaptureStatus.decodeResponse([UInt8](hex: "0a0408000801")))
    }
    func testMalformedProtobuf() throws {
        for hex in ["80", "0a086869", "00", "0d01", "08ffffffffffffffffff02"] {
            XCTAssertThrowsError(try Protobuf.fields([UInt8](hex: hex)))
        }
    }
}

@MainActor final class FakeLink: CameraLink {
    var isReady = true
    var recording = false
    var unknown = false
    var reconnects = 0
    var calls: [CameraCommand] = []
    var failCapture = false
    var ignoreCapture = false
    var loseCaptureReply = false
    var failStatusCall: Int?
    private var statusCalls = 0
    var queryHook: (() -> Void)?
    var waitForQuery: (() async -> Void)?
    var captureHook: (() -> Void)?
    func requestReconnect() { reconnects += 1 }
    func request(_ command: CameraCommand) async throws -> [UInt8] {
        calls.append(command)
        guard isReady else { throw SessionError.disconnected }
        if command == .telemetry { return [0x12, 0] }
        if command == .status {
            statusCalls += 1
            if statusCalls == failStatusCall { throw SimulatedReplyError.timeout }
            queryHook?()
            await waitForQuery?()
            return [0x0a, 6, 8, unknown ? 99 : (recording ? 1 : 0), 0x10, 0, 0x50, 0]
        }
        if failCapture { throw SessionError.notConfirmed }
        if !ignoreCapture { recording = command == .start }
        captureHook?()
        if loseCaptureReply { throw SimulatedReplyError.timeout }
        return []
    }
}

private enum SimulatedReplyError: Error { case timeout }

final class SessionTests: XCTestCase {
    @MainActor func testLostReplyAndFailedRecoveryReadStayUnknownWithoutRetryLoop() async {
        let link = FakeLink(); link.recording = true
        link.loseCaptureReply = true; link.failStatusCall = 2
        let remote = RecordingSession(link: link, delay: {})
        var confirmations = 0; remote.confirmed = { _ in confirmations += 1 }
        do { _ = try await remote.stop(); XCTFail("Missing verification must fail") }
        catch { XCTAssertEqual(error as? SimulatedReplyError, .timeout) }
        XCTAssertFalse(link.recording)
        XCTAssertEqual(remote.state, .unknown)
        XCTAssertEqual(confirmations, 0)
        XCTAssertEqual(link.calls, [.status, .stop, .status])
        XCTAssertFalse(remote.busy)
        XCTAssertFalse(remote.pendingStop)
    }

    @MainActor func testLostReplyAndDisconnectDoNotReconnectOrReplayCapture() async {
        let link = FakeLink(); link.recording = true; link.loseCaptureReply = true
        link.captureHook = { link.isReady = false }
        let remote = RecordingSession(link: link, delay: {})
        do { _ = try await remote.stop(); XCTFail("No current connection for verification") }
        catch { XCTAssertEqual(error as? SimulatedReplyError, .timeout) }
        XCTAssertEqual(link.calls, [.status, .stop])
        XCTAssertEqual(link.reconnects, 0)
        XCTAssertEqual(remote.state, .unknown)
        XCTAssertFalse(remote.pendingStop)
    }

    @MainActor func testCancellationAfterCaptureDoesNotStartRecoveryRead() async {
        let link = FakeLink(); link.recording = true; link.loseCaptureReply = true
        link.captureHook = { withUnsafeCurrentTask { $0?.cancel() } }
        let remote = RecordingSession(link: link, delay: {})
        let command = Task { try await remote.stop() }
        do { _ = try await command.value; XCTFail("Cancelled work must not recover") } catch {}
        XCTAssertEqual(link.calls, [.status, .stop])
        XCTAssertEqual(remote.state, .unknown)
        XCTAssertFalse(remote.busy)
    }

    @MainActor func testAppliedStopWithLostReplyIsVerifiedWithoutRepeatingCapture() async throws {
        let link = FakeLink(); link.recording = true; link.loseCaptureReply = true
        let remote = RecordingSession(link: link, delay: {})
        var confirmations: [ControlResult] = []
        remote.confirmed = { confirmations.append($0) }
        let result = try await remote.stop()
        XCTAssertFalse(link.recording)
        XCTAssertEqual(result, .stopped)
        XCTAssertEqual(confirmations, [.stopped])
        XCTAssertEqual(link.calls, [.status, .stop, .status])
    }

    @MainActor func testAppliedStartWithLostReplyIsVerifiedWithoutRepeatingCapture() async throws {
        let link = FakeLink(); link.loseCaptureReply = true
        let remote = RecordingSession(link: link, delay: {})
        let result = try await remote.start()
        XCTAssertEqual(result, .recording)
        XCTAssertEqual(link.calls, [.status, .start, .status])
    }

    @MainActor func testLostPostStopStatusReplyGetsOneReadOnlyRecovery() async throws {
        let link = FakeLink(); link.recording = true; link.failStatusCall = 2
        let remote = RecordingSession(link: link, delay: {})
        let result = try await remote.stop()
        XCTAssertEqual(result, .stopped)
        XCTAssertEqual(link.calls, [.status, .stop, .status, .status])
    }

    @MainActor func testLostReplyWithoutActualStopStillFailsWithoutReplay() async {
        let link = FakeLink(); link.recording = true
        link.loseCaptureReply = true; link.ignoreCapture = true
        let remote = RecordingSession(link: link, delay: {})
        var confirmations: [ControlResult] = []
        remote.confirmed = { confirmations.append($0) }
        do { _ = try await remote.stop(); XCTFail("An unobserved STOP must not be reported as success") }
        catch { XCTAssertEqual(error as? SimulatedReplyError, .timeout) }
        XCTAssertTrue(link.recording)
        XCTAssertEqual(remote.state, .unknown)
        XCTAssertTrue(confirmations.isEmpty)
        XCTAssertEqual(link.calls, [.status, .stop, .status])
    }

    @MainActor func testRefreshKeepsTransportExclusiveWithoutDisablingControls() async throws {
        let link = FakeLink()
        let remote = RecordingSession(link: link)
        var reply: CheckedContinuation<Void, Never>?
        link.waitForQuery = { await withCheckedContinuation { reply = $0 } }
        let poll = Task { try await remote.refresh() }
        while reply == nil { await Task.yield() }
        XCTAssertTrue(remote.busy)
        XCTAssertTrue(remote.isRefreshing)
        XCTAssertFalse(remote.commandBusy)
        do { _ = try await remote.start(); XCTFail("Transport must stay exclusive") }
        catch { XCTAssertEqual(error as? SessionError, .busy) }
        XCTAssertEqual(link.calls, [.status])
        reply?.resume()
        _ = try await poll.value
        XCTAssertFalse(remote.busy)
        XCTAssertFalse(remote.isRefreshing)
        XCTAssertFalse(remote.commandBusy)
    }

    @MainActor func testRoutineRefreshKeepsLastObservationUntilReply() async throws {
        let link = FakeLink()
        let remote = RecordingSession(link: link)
        _ = try await remote.refresh()
        link.queryHook = { XCTAssertEqual(remote.state, .stopped) }
        link.recording = true
        _ = try await remote.refresh()
        XCTAssertEqual(remote.state, .recording)
        XCTAssertEqual(link.calls, [.status, .status])
    }

    @MainActor func testRoutineRefreshClearsLastObservationOnFailureOrUnknown() async throws {
        let link = FakeLink()
        let remote = RecordingSession(link: link)
        _ = try await remote.refresh()
        link.unknown = true
        _ = try await remote.refresh()
        XCTAssertEqual(remote.state, .unknown)
        link.unknown = false
        _ = try await remote.refresh()
        link.queryHook = { link.isReady = false; remote.connectionLost() }
        do { _ = try await remote.refresh(); XCTFail("Must fail") } catch {}
        XCTAssertEqual(remote.state, .unknown)
        XCTAssertFalse(remote.isRefreshing)
        XCTAssertFalse(remote.busy)
    }

    @MainActor func testStartAndStopConfirmedByQuery() async throws {
        let link = FakeLink()
        let remote = RecordingSession(link: link, delay: {})
        let start = try await remote.start()
        XCTAssertEqual(start, .recording)
        XCTAssertEqual(link.calls, [.status, .start, .status])
        let stop = try await remote.stop()
        XCTAssertEqual(stop, .stopped)
        XCTAssertEqual(remote.state, .stopped)
    }
    @MainActor func testOfflineStopQueriesThenSendsExplicitStop() async throws {
        let link = FakeLink(); link.isReady = false; link.recording = true
        let remote = RecordingSession(link: link, delay: {})
        let result = try await remote.stop()
        XCTAssertEqual(result, .stopQueued); XCTAssertEqual(link.reconnects, 1)
        XCTAssertTrue(link.calls.isEmpty)
        link.isReady = true
        try await remote.connectionReady()
        XCTAssertEqual(link.calls, [.status, .stop, .status])
        XCTAssertFalse(remote.pendingStop); XCTAssertEqual(remote.state, .stopped)
    }
    @MainActor func testExplicitStartLeavesExistingRecordingRunning() async throws {
        let link = FakeLink(); link.recording = true
        let remote = RecordingSession(link: link, delay: {})
        let result = try await remote.start()
        XCTAssertEqual(result, .recording)
        XCTAssertEqual(link.calls, [.status])
        XCTAssertTrue(link.recording)
    }

    @MainActor func testQueuedStopClearsWithoutCaptureWhenCameraAlreadyStopped() async throws {
        let link = FakeLink(); link.isReady = false
        let remote = RecordingSession(link: link, delay: {})
        _ = try await remote.stop()
        link.isReady = true
        try await remote.connectionReady()
        XCTAssertEqual(link.calls, [.status])
        XCTAssertFalse(remote.pendingStop)
        XCTAssertEqual(remote.state, .stopped)
    }

    @MainActor func testQueuedStopWaitsForKnownStateAfterReconnect() async throws {
        let link = FakeLink(); link.isReady = false; link.recording = true
        let remote = RecordingSession(link: link, delay: {})
        _ = try await remote.stop()
        link.isReady = true; link.unknown = true
        do { try await remote.connectionReady(); XCTFail("Unknown must not send STOP") }
        catch { XCTAssertEqual(error as? SessionError, .unknownState) }
        XCTAssertEqual(link.calls, [.status])
        XCTAssertTrue(remote.pendingStop)
        link.unknown = false
        try await remote.connectionReady()
        XCTAssertEqual(link.calls, [.status, .status, .stop, .status])
        XCTAssertFalse(remote.pendingStop)
        XCTAssertFalse(link.recording)
    }

    @MainActor func testOfflineStartIsNotQueued() async {
        let link = FakeLink(); link.isReady = false
        let remote = RecordingSession(link: link)
        do { _ = try await remote.start(); XCTFail("Should reject") } catch {}
        XCTAssertFalse(remote.pendingStop); XCTAssertTrue(link.calls.isEmpty)
    }
    @MainActor func testDisconnectedToggleOnlyQueuesStop() async throws {
        let link = FakeLink(); link.isReady = false
        let remote = RecordingSession(link: link)
        let result = try await remote.toggle()
        XCTAssertEqual(result, .stopQueued); XCTAssertTrue(link.calls.isEmpty)
    }
    @MainActor func testLostAcknowledgementNeverReplayed() async throws {
        let link = FakeLink(); link.isReady = false; link.recording = true
        let remote = RecordingSession(link: link, delay: {})
        _ = try await remote.stop()
        link.isReady = true; link.failCapture = true
        do { try await remote.connectionReady(); XCTFail("Should fail") } catch {}
        XCTAssertFalse(remote.pendingStop)
        try await remote.connectionReady()
        XCTAssertEqual(link.calls.filter { $0 == .stop }.count, 1)
    }
    @MainActor func testQueuedStopCancellationDuringQuery() async throws {
        let link = FakeLink(); link.isReady = false; link.recording = true
        let remote = RecordingSession(link: link, delay: {})
        _ = try await remote.stop()
        link.isReady = true; link.queryHook = { remote.cancelPendingStop() }
        do { try await remote.connectionReady(); XCTFail("Should cancel") } catch {}
        XCTAssertEqual(link.calls, [.status])
    }
    @MainActor func testAlreadyStoppedNeverToggles() async throws {
        let link = FakeLink()
        let session = RecordingSession(link: link)
        _ = try await session.stop()
        XCTAssertEqual(link.calls, [.status])
    }
    @MainActor func testUnknownStateRefusesCapture() async {
        let link = FakeLink(); link.unknown = true
        let remote = RecordingSession(link: link)
        do { _ = try await remote.toggle(); XCTFail("Unknown should fail") } catch {}
        XCTAssertEqual(link.calls, [.status])
    }
    @MainActor func testAckWithoutActualStateChangeDoesNotConfirm() async {
        let link = FakeLink(); link.ignoreCapture = true
        let remote = RecordingSession(link: link, delay: {})
        var confirmations = 0; remote.confirmed = { _ in confirmations += 1 }
        do { _ = try await remote.start(); XCTFail("Must not confirm") } catch {}
        XCTAssertEqual(confirmations, 0); XCTAssertEqual(remote.state, .unknown)
    }
    @MainActor func testBusyRejectsOverlappingToggle() async throws {
        let link = FakeLink()
        var continuation: CheckedContinuation<Void, Never>?
        let remote = RecordingSession(link: link, delay: { await withCheckedContinuation { continuation = $0 } })
        let first = Task { try await remote.start() }
        while continuation == nil { await Task.yield() }
        XCTAssertTrue(remote.commandBusy)
        XCTAssertFalse(remote.isRefreshing)
        do { _ = try await remote.toggle(); XCTFail("Overlap should fail") } catch {}
        continuation?.resume(); _ = try await first.value
        XCTAssertEqual(link.calls.filter { $0 == .start }.count, 1)
    }

    @MainActor func testDisconnectDuringStateQueryCannotStart() async {
        let link = FakeLink()
        let remote = RecordingSession(link: link)
        link.queryHook = { link.isReady = false; remote.connectionLost() }
        do { _ = try await remote.start(); XCTFail("Must fail") } catch {}
        XCTAssertEqual(link.calls, [.status]); XCTAssertEqual(remote.state, .unknown)
    }

    @MainActor func testToggleUsesFreshCameraStateAfterManualChange() async throws {
        let link = FakeLink()
        let remote = RecordingSession(link: link, delay: {})
        _ = try await remote.refresh()
        link.recording = true
        let result = try await remote.toggle()
        XCTAssertEqual(result, .stopped)
        XCTAssertEqual(link.calls, [.status, .status, .stop, .status])
    }

    @MainActor func testRepeatedOfflineStopDoesNotDuplicateCapture() async throws {
        let link = FakeLink(); link.isReady = false; link.recording = true
        let remote = RecordingSession(link: link, delay: {})
        _ = try await remote.stop(); _ = try await remote.stop()
        link.isReady = true
        try await remote.connectionReady(); try await remote.connectionReady()
        XCTAssertEqual(link.calls.filter { $0 == .stop }.count, 1)
    }

    @MainActor func testCancellationBeforeTransmissionDoesNotStart() async {
        let link = FakeLink()
        let remote = RecordingSession(link: link, delay: {})
        let task = Task { try await remote.start() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Must cancel") } catch {}
        XCTAssertFalse(link.calls.contains(.start)); XCTAssertEqual(remote.state, .unknown)
    }
}

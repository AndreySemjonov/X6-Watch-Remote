import Foundation

@MainActor public protocol CameraLink: AnyObject {
    var isReady: Bool { get }
    func requestReconnect()
    func request(_ command: CameraCommand) async throws -> [UInt8]
}

public enum SessionError: Error, LocalizedError {
    case busy, disconnected, unknownState, notConfirmed, cancelled, deadlineExceeded
    public var errorDescription: String? {
        switch self {
        case .busy: return "A camera command is already in progress."
        case .disconnected: return "Camera disconnected. START was not queued."
        case .unknownState: return "Camera state is unknown. Open the app and check the camera."
        case .notConfirmed: return "Recording change was not confirmed."
        case .cancelled: return "The queued request was cancelled."
        case .deadlineExceeded: return "Camera command timed out. Check the camera; recording may still be active."
        }
    }
}

public enum ControlResult: String, Sendable { case recording, stopped, stopQueued }

/// The watch UI and App Intents share this instance. Never infer STOP from cache.
@MainActor public final class RecordingSession {
    public private(set) var state: RecordingState = .unknown
    public private(set) var pendingStop = false
    public private(set) var busy = false
    public private(set) var isRefreshing = false
    public private(set) var duration = RecordingDuration()
    /// STOP may finish physically before status reports idle while the camera
    /// saves the clip. START keeps its original eight checks.
    public static let stopConfirmationWindow: TimeInterval = 15
    /// Where the latest capture attempt reached, for failure summaries, e.g.
    /// "STOP reply". Cleared with clearCaptureStage() at each user command.
    public private(set) var captureStage: String?
    /// Polling owns the transport, but should not dim the user controls.
    public var commandBusy: Bool { busy && !isRefreshing }
    public var changed: (() -> Void)?
    public var confirmed: ((ControlResult) -> Void)?
    public var diagnostic: ((String) -> Void)?
    private let link: any CameraLink
    private let delay: () async throws -> Void
    private let now: () -> TimeInterval
    private var cancelVersion = 0
    public init(link: any CameraLink,
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                delay: @escaping () async throws -> Void = {
        try await Task.sleep(nanoseconds: 500_000_000)
    }) { self.link = link; self.now = now; self.delay = delay }

    public func connectionLost() { state = .unknown; changed?() }
    public func cancelPendingStop() { pendingStop = false; cancelVersion += 1; changed?() }
    public func invalidate() { state = .unknown; changed?() }
    public func clearCaptureStage() { captureStage = nil }

    public func refresh() async throws -> CaptureStatus {
        guard !busy else { throw SessionError.busy }
        busy = true; isRefreshing = true; changed?()
        defer { busy = false; isRefreshing = false; changed?() }
        // Keep the last observation visible during a routine read. A failed or
        // unsupported response still clears it; commands always query afresh.
        return try await query(preserveDisplay: true)
    }

    public func start() async throws -> ControlResult { try await perform(desired: .recording) }
    /// Shares the single-request gate with capture/polling, but telemetry errors
    /// do not invalidate recording. Caller cancels this read before a user command.
    public func refreshTelemetry() async throws -> CameraTelemetry {
        guard !busy else { throw SessionError.busy }
        busy = true; isRefreshing = true; changed?()
        defer { busy = false; isRefreshing = false; changed?() }
        try CommandDeadline.check()
        guard link.isReady else { throw SessionError.disconnected }
        let body = try await link.request(.telemetry)
        try CommandDeadline.check()
        guard link.isReady else { throw SessionError.disconnected }
        return try CameraTelemetry.decodeResponse(body)
    }
    public func stop() async throws -> ControlResult {
        guard !busy else { throw SessionError.busy }
        if !link.isReady {
            pendingStop = true; state = .unknown; changed?()
            link.requestReconnect()
            confirmed?(.stopQueued)
            return .stopQueued
        }
        return try await perform(desired: .stopped)
    }

    /// A disconnected physical-button action can only queue STOP, never START.
    public func toggle() async throws -> ControlResult {
        guard !busy else { throw SessionError.busy }
        if pendingStop { return .stopQueued }
        if !link.isReady { return try await stop() }
        busy = true; changed?()
        defer { busy = false; changed?() }
        let snapshot = try await query()
        guard snapshot.recording != .unknown else { throw SessionError.unknownState }
        return try await apply(snapshot.recording == .recording ? .stopped : .recording, before: snapshot)
    }

    /// The foreground open-or-toggle action must never queue capture on loss.
    /// Validate the same connection again after the asynchronous status read.
    /// nil means this press only opens/reconnects, including a mid-read reconnect.
    public func toggleConnectedOnly(isCurrentConnection: () -> Bool) async throws -> ControlResult? {
        guard !busy else { throw SessionError.busy }
        guard link.isReady, isCurrentConnection() else {
            link.requestReconnect()
            return nil
        }
        if pendingStop { return .stopQueued }
        busy = true; changed?()
        defer { busy = false; changed?() }
        let snapshot = try await query()
        guard isCurrentConnection() else { return nil }
        guard snapshot.recording != .unknown else { throw SessionError.unknownState }
        return try await apply(snapshot.recording == .recording ? .stopped : .recording, before: snapshot)
    }

    public func connectionReady() async throws {
        guard !busy else { return }
        if pendingStop { _ = try await perform(desired: .stopped, queued: true) }
        else { _ = try await refresh() }
    }

    private func query(preserveDisplay: Bool = false) async throws -> CaptureStatus {
        if !preserveDisplay { state = .unknown; changed?() }
        do {
            try CommandDeadline.check()
            guard link.isReady else { throw SessionError.disconnected }
            let body = try await link.request(.status)
            let snapshot = try CaptureStatus.decodeResponse(body)
            if !preserveDisplay {
                diagnostic?("capture_status raw_state=\(snapshot.rawState.map(String.init) ?? "nil") elapsed=\(snapshot.elapsed.map(String.init) ?? "nil") observed=\(snapshot.recording.rawValue) body=\(Array(body.prefix(64)).hex)")
            }
            try CommandDeadline.check()
            guard link.isReady else { throw SessionError.disconnected }
            duration.observe(snapshot, at: ProcessInfo.processInfo.systemUptime)
            state = snapshot.recording; changed?()
            return snapshot
        } catch { state = .unknown; changed?(); throw error }
    }

    private func perform(desired: RecordingState, queued: Bool = false) async throws -> ControlResult {
        guard !busy else { throw SessionError.busy }
        guard link.isReady else { throw SessionError.disconnected }
        guard desired != .recording || !pendingStop else { throw SessionError.busy }
        busy = true; changed?()
        defer { busy = false; changed?() }
        let version = cancelVersion
        let snapshot = try await query()
        if queued && (!pendingStop || version != cancelVersion) { throw SessionError.cancelled }
        return try await apply(desired, before: snapshot)
    }

    private func apply(_ desired: RecordingState, before: CaptureStatus) async throws -> ControlResult {
        guard before.recording != .unknown else { throw SessionError.unknownState }
        let result: ControlResult = desired == .recording ? .recording : .stopped
        if before.recording == desired {
            pendingStop = false; changed?(); confirmed?(result); return result
        }
        try CommandDeadline.check()
        // Clear BEFORE transmission: after a lost reply, delivery is ambiguous.
        pendingStop = false; state = .unknown; changed?()
        var stage = "capture_reply"
        let name = desired == .recording ? "START" : "STOP"
        captureStage = "\(name) reply"
        do {
            diagnostic?("capture_requested desired=\(desired.rawValue)")
            let reply = try await link.request(desired == .recording ? .start : .stop)
            stage = "state_confirmation"
            captureStage = "\(name) confirmation"
            diagnostic?("capture_acknowledged desired=\(desired.rawValue) reply_bytes=\(reply.count)")
            // STOP may have completed physically before the status endpoint
            // reports idle. Keep checking within the confirmation window and
            // the enclosing command deadline. Never replay the capture command.
            let attempts = desired == .stopped ? 30 : 8
            let expires = desired == .stopped ? now() + Self.stopConfirmationWindow : .infinity
            for _ in 0..<attempts {
                try CommandDeadline.check()
                guard now() < expires else { break }
                try await delay()
                if try await query().recording == desired {
                    captureStage = "\(name) confirmed"
                    confirmed?(result); return result
                }
            }
            throw SessionError.notConfirmed
        } catch {
            diagnostic?("capture_unconfirmed desired=\(desired.rawValue) stage=\(stage) error=\(String(reflecting: error))")
            // Delivery can succeed even when its reply is lost. Make just one
            // fresh, read-only check on the existing connection. Never repeat
            // START/STOP, reconnect here, or turn an unknown state into success.
            if (try? CommandDeadline.check()) != nil, link.isReady {
                diagnostic?("capture_recovery_read desired=\(desired.rawValue)")
                do {
                    let snapshot = try await query()
                    if snapshot.recording == desired {
                        captureStage = "\(name) confirmed"
                        diagnostic?("capture_recovered desired=\(desired.rawValue)")
                        confirmed?(result)
                        return result
                    }
                    diagnostic?("capture_recovery_mismatch observed=\(snapshot.recording.rawValue)")
                } catch {
                    diagnostic?("capture_recovery_failed error=\(String(reflecting: error))")
                }
            }
            state = .unknown; changed?(); throw error
        }
    }
}

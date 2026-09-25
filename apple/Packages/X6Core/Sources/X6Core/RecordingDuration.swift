import Foundation

/// Camera elapsed time, interpolated locally between the existing status reads.
/// A runtime gap never leaves an apparently live timer ticking indefinitely.
public struct RecordingDuration: Sendable {
    private var elapsed: UInt64?
    private var sampledAt: TimeInterval?
    public init() {}
    public mutating func observe(_ status: CaptureStatus, at time: TimeInterval) {
        elapsed = status.recording == .recording ? status.elapsed : nil
        sampledAt = time
    }
    public func text(state: RecordingState, at time: TimeInterval) -> String {
        guard let sampledAt, (0...10).contains(time - sampledAt) else { return "--:--" }
        if state == .stopped { return "00:00" }
        guard state == .recording, let elapsed, elapsed <= 359_999 else { return "--:--" }
        let seconds = min(359_999, elapsed + UInt64((time - sampledAt).rounded(.down)))
        if seconds >= 3600 { return String(format: "%02d:%02d:%02d", Int(seconds / 3600), Int(seconds / 60 % 60), Int(seconds % 60)) }
        return String(format: "%02d:%02d", Int(seconds / 60), Int(seconds % 60))
    }
}

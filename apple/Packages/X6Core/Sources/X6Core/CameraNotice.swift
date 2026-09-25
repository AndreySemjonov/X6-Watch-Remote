/// Event notifications describe observations, never a continuously live status.
public enum CameraNotice: String, Sendable {
    case connected, disconnected, recording, stopped, stopQueued, unknown, failed, budget

    public var title: String {
        switch self {
        case .connected: return "X6 connected"
        case .disconnected: return "X6 disconnected"
        case .recording: return "X6 recording"
        case .stopped: return "X6 stopped"
        case .stopQueued: return "X6 STOP queued"
        case .unknown: return "X6 state unknown"
        case .failed: return "X6 command not confirmed"
        case .budget: return "X6 background Bluetooth limited"
        }
    }

    public var body: String {
        switch self {
        case .connected: return "Bluetooth connected. Checking camera recording state."
        case .disconnected: return "Recording state is unknown. The camera may still be recording."
        case .recording: return "Camera confirmed recording."
        case .stopped: return "Camera confirmed stopped."
        case .stopQueued: return "Camera may still be recording. STOP awaits reconnection and Watch runtime."
        case .unknown: return "Could not verify camera state. The camera may still be recording."
        case .failed: return "Check the camera. No recording change was confirmed."
        case .budget: return "Background updates may stop. Open X6 Remote to check the camera."
        }
    }
}

/// Suppress repeated polling/heartbeat notices, but report real transitions.
public struct CameraNoticeTracker {
    private var connected = false
    private var state: RecordingState = .unknown
    public init() {}

    public mutating func connectionChanged(_ ready: Bool) -> CameraNotice? {
        guard ready != connected else { return nil }
        connected = ready
        state = .unknown
        return ready ? .connected : .disconnected
    }

    public mutating func observed(_ value: RecordingState) -> CameraNotice? {
        guard connected, value != state else { return nil }
        state = value
        switch value {
        case .recording: return .recording
        case .stopped: return .stopped
        case .unknown: return .unknown
        }
    }

    public mutating func confirmed(_ result: ControlResult) -> CameraNotice {
        switch result {
        case .recording: state = .recording; return .recording
        case .stopped: state = .stopped; return .stopped
        case .stopQueued: state = .unknown; return .stopQueued
        }
    }
}

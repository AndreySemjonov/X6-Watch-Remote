/// The visible button always selects an explicit command. Unknown state must
/// never turn a tap into an accidental START, even after a connection change.
public enum RecordingControl: Equatable, Sendable {
    case stopped, recording, unknown, disconnected, stopQueued, working

    public enum Action: Equatable, Sendable { case start, stop, status }

    public init(state: RecordingState, ready: Bool, busy: Bool, pendingStop: Bool) {
        if pendingStop { self = .stopQueued }
        else if busy { self = .working }
        else if !ready { self = .disconnected }
        else {
            switch state {
            case .stopped: self = .stopped
            case .recording: self = .recording
            case .unknown: self = .unknown
            }
        }
    }

    public var action: Action? {
        switch self {
        case .stopped: return .start
        case .recording, .disconnected: return .stop
        case .unknown: return .status
        case .stopQueued, .working: return nil
        }
    }

    public var title: String {
        switch self {
        case .stopped: return "STOPPED"
        case .recording: return "RECORDING"
        case .unknown: return "STATE UNKNOWN"
        case .disconnected: return "DISCONNECTED"
        case .stopQueued: return "STOP QUEUED"
        case .working: return "CHECKING CAMERA"
        }
    }

    public var buttonTitle: String {
        switch self {
        case .stopped: return "START"
        case .recording: return "STOP"
        case .unknown: return "CHECK STATE"
        case .disconnected: return "QUEUE STOP"
        case .stopQueued, .working: return "WAITING"
        }
    }

    public var hint: String {
        switch self {
        case .stopped: return "Tap to record."
        case .recording: return "Tap to stop."
        case .unknown: return "Read camera state before recording."
        case .disconnected: return "Camera may still be recording."
        case .stopQueued: return "Stop requested. Awaiting camera."
        case .working: return "Waiting for camera confirmation."
        }
    }
}

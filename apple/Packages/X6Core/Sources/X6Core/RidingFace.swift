import Foundation

/// What the riding screen says for a control state: one large headline, an
/// optional hint, and the screen tint. Values only, so it can be tested without UI.
public struct RidingFace: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case recording, attention, neutral }

    public static let lowCameraBatteryPercent = 20
    public static let lowStorageBytes: UInt64 = 4_000_000_000

    public let headline: String
    public let hint: String?
    public let tone: Tone

    /// `connectionMessage` is the link's own status text while disconnected, such
    /// as "Bluetooth unavailable". Generic progress texts are not repeated.
    public init(control: RecordingControl, workingTitle: String, connectionMessage: String? = nil) {
        switch control {
        case .recording:
            headline = "● REC"; hint = nil; tone = .recording
        case .stopped:
            headline = "STOPPED"; hint = nil; tone = .neutral
        case .working:
            headline = workingTitle; hint = nil; tone = .neutral
        case .disconnected:
            headline = "RECONNECTING…"
            hint = Self.specific(connectionMessage) ?? control.hint
            tone = .attention
        case .stopQueued:
            headline = "STOP QUEUED"; hint = control.hint; tone = .attention
        case .unknown:
            headline = "CHECK STATE"; hint = control.hint; tone = .attention
        }
    }

    public static func batteryLow(_ percent: Int?) -> Bool {
        percent.map { $0 <= lowCameraBatteryPercent } ?? false
    }

    private static func specific(_ message: String?) -> String? {
        guard let message, !message.isEmpty else { return nil }
        let generic = ["Connecting…", "Disconnected", "Connected", "Ready to connect",
                       "Discovering camera services…", "Paused in background"]
        return generic.contains(message) ? nil : message
    }
}

import Foundation

/// Lifetime of the optional location-backed riding session.
/// Since 0.1.25 it starts when the camera connects while X6 Remote is on screen
/// (watchOS lets a location session start only then), not on every open: opening
/// X6 Remote just to look at something else no longer keeps it running for hours.
/// It ends on an explicit user request or after four hours without the app being
/// opened again. Camera disconnection does not end it: underwater outages are
/// exactly when the retained runtime is needed.
public struct RidingSessionPolicy: Sendable {
    public static let maximumDuration: TimeInterval = 4 * 60 * 60
    public enum Decision: Equatable, Sendable { case none, start, stop }

    public private(set) var wanted = false
    private var deadline: TimeInterval?
    /// Set by "End ride": no automatic restart until X6 Remote is opened again.
    private var endedByUser = false

    public init() {}

    /// The app became visible after a cold launch or from the background.
    /// Wrist raises while already frontmost are not an "open". Opening always
    /// extends a running session; it starts one only when automatic start is on
    /// and the camera is already connected.
    public mutating func opened(enabled: Bool, cameraConnected: Bool, at now: TimeInterval) -> Decision {
        endedByUser = false
        if wanted { deadline = now + Self.maximumDuration; return .none }
        guard enabled, cameraConnected else { return .none }
        return userStarted(at: now)
    }

    /// The camera is connected. Starts a session when automatic start is on, the
    /// app is active and the rider hasn't ended one since the app was opened.
    public mutating func cameraConnected(enabled: Bool, active: Bool, at now: TimeInterval) -> Decision {
        guard enabled, active, !wanted, !endedByUser else { return .none }
        return userStarted(at: now)
    }

    public mutating func userStarted(at now: TimeInterval) -> Decision {
        deadline = now + Self.maximumDuration
        if wanted { return .none }
        wanted = true
        return .start
    }

    public mutating func userEnded() -> Decision {
        endedByUser = true
        return wanted ? stop() : .none
    }

    public mutating func check(at now: TimeInterval) -> Decision {
        guard wanted, let deadline, now >= deadline else { return .none }
        return stop()
    }

    public func remaining(at now: TimeInterval) -> TimeInterval? {
        guard wanted, let deadline else { return nil }
        return max(0, deadline - now)
    }

    private mutating func stop() -> Decision {
        wanted = false; deadline = nil
        return .stop
    }
}

/// Status polling cadence. The visible, active screen polls quickly; frontmost
/// wrist-down or a background riding session relies on camera status events and
/// a slower read. Without either, polling stops and the OS may suspend the app.
public enum StatusPollingSchedule {
    public static let activeInterval: TimeInterval = 3
    public static let passiveInterval: TimeInterval = 10

    public static func interval(active: Bool, frontmost: Bool, riding: Bool) -> TimeInterval? {
        if active { return activeInterval }
        if frontmost || riding { return passiveInterval }
        return nil
    }
}

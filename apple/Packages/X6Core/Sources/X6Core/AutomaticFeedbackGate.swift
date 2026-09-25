/// User-requested command feedback bypasses this gate. Automatic recovery
/// failures get at most one alert per interval; diagnostics still record all.
public struct AutomaticFeedbackGate {
    private var lastAlert: Double?
    private let interval: Double
    public init(interval: Double = 30) { self.interval = interval }

    public mutating func allow(at uptime: Double) -> Bool {
        if let lastAlert, uptime - lastAlert < interval { return false }
        lastAlert = uptime
        return true
    }
}

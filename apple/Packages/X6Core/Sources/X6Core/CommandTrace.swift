/// A bounded command transcript that later heartbeat/reconnect logs cannot
/// overwrite. The user can read the active trace or the last completed trace.
public struct CommandTrace {
    private var active: [String]?
    private var omitted = 0
    private let limit: Int
    public private(set) var lastReport: String
    /// Replaced only by another failure, so later successful presses keep it.
    public private(set) var lastFailureReport: String
    public init(lastReport: String = "No command recorded yet.",
                lastFailureReport: String = "No failed command recorded yet.", limit: Int = 120) {
        self.lastReport = lastReport
        self.lastFailureReport = lastFailureReport
        self.limit = max(4, limit)
    }
    public var isActive: Bool { active != nil }
    public var report: String { active.map(render) ?? lastReport }

    @discardableResult public mutating func begin(context: [String]) -> Bool {
        guard active == nil else { return false }
        active = Array(context.suffix(20)); omitted = 0
        trim()
        return true
    }
    public mutating func append(_ line: String) {
        guard active != nil else { return }
        active?.append(line); trim()
    }
    /// A failure summary also keeps this trace as the last failed report.
    public mutating func finish(failureSummary: String? = nil) {
        guard let active else { return }
        lastReport = render(active)
        if let failureSummary { lastFailureReport = failureSummary + "\n\n" + lastReport }
        self.active = nil
    }
    /// A command rejected before it began (e.g. busy) has no trace of its own.
    /// Keep recent context as the failed report without touching an active trace.
    public mutating func recordFailure(_ summary: String, context: [String]) {
        lastFailureReport = ([summary, ""] + context.suffix(limit)).joined(separator: "\n")
    }
    private mutating func trim() {
        guard let count = active?.count, count > limit else { return }
        // Retain both the command's beginning and its most recent events.
        let removed = count - limit
        active?.removeSubrange((limit / 2)..<(limit / 2 + removed))
        omitted += removed
    }
    private func render(_ lines: [String]) -> String {
        var result = lines
        if omitted > 0 {
            result.insert("[\(omitted) intermediate events omitted]", at: min(limit / 2, result.count))
        }
        return result.joined(separator: "\n")
    }
}

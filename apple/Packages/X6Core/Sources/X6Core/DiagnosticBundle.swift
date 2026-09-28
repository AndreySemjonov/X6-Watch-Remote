import Foundation

/// One plain-text file with everything needed to debug a problem later: a header
/// (build, device, settings, state) and the command reports and detailed logs.
public enum DiagnosticBundle {
    public static func fileName(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "x6-logs-\(formatter.string(from: date)).txt"
    }

    public static func make(header: [(String, String)], sections: [(String, String)]) -> String {
        var lines = ["X6 Remote diagnostic logs", ""]
        lines += header.map { "\($0.0): \($0.1)" }
        for (title, body) in sections {
            lines += ["", "===== \(title) =====", body.isEmpty ? "(empty)" : body]
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

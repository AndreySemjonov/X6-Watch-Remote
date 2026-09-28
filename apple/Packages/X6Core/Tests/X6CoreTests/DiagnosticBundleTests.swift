import XCTest
@testable import X6Core

final class DiagnosticBundleTests: XCTestCase {
    func testFileNameIsSortableAndLocaleIndependent() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(DiagnosticBundle.fileName(at: date, timeZone: TimeZone(identifier: "UTC")!),
                       "x6-logs-20260921-141320.txt")
    }

    func testBundleKeepsHeaderOrderAndMarksEmptySections() {
        let text = DiagnosticBundle.make(
            header: [("Build", "0.1.24 (25)"), ("Detailed logging", "on")],
            sections: [("Last failed command", "FAILED …"), ("Detailed log", "")])
        XCTAssertEqual(text, """
            X6 Remote diagnostic logs

            Build: 0.1.24 (25)
            Detailed logging: on

            ===== Last failed command =====
            FAILED …

            ===== Detailed log =====
            (empty)

            """)
    }
}

import XCTest
@testable import X6Core

final class ConnectionRecoveryTests: XCTestCase {
    func testFailedConnectBacksOffAndLaterRetryIsAllowed() {
        var recovery = ConnectionRecovery()
        recovery.began(at: 0)
        recovery.failed(at: 1)
        XCTAssertFalse(recovery.canRetry(at: 1.5))
        XCTAssertTrue(recovery.canRetry(at: 2))
        recovery.began(at: 2); recovery.failed(at: 3)
        XCTAssertFalse(recovery.canRetry(at: 4.9))
        XCTAssertTrue(recovery.canRetry(at: 5))
        recovery.ready()
        XCTAssertTrue(recovery.canRetry(at: 5))
        recovery.began(at: 5); recovery.failed(at: 6)
        XCTAssertTrue(recovery.canRetry(at: 7))
    }

    func testSetupTimeoutIncludesServiceDiscoveryAndLongRuntimeGap() {
        var recovery = ConnectionRecovery()
        recovery.began(at: 100)
        XCTAssertFalse(recovery.setupExpired(at: 111))
        XCTAssertTrue(recovery.setupExpired(at: 112))
        XCTAssertTrue(recovery.setupExpired(at: 1300))
        recovery.ready()
        XCTAssertFalse(recovery.setupExpired(at: 1300))
    }

    func testBackoffRemainsBoundedAfterLongFailureRun() {
        var recovery = ConnectionRecovery()
        for i in 0..<100 {
            let time = Double(i * 20)
            recovery.began(at: time); recovery.failed(at: time)
            XCTAssertTrue(recovery.canRetry(at: time + 8))
        }
    }
}

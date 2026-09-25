import Foundation

/// A retry clock driven only while the app/intent has execution time.
/// Background disconnects still use Core Bluetooth's one pending connection.
public struct ConnectionRecovery: Sendable {
    public private(set) var attemptStarted: TimeInterval?
    public private(set) var retryAfter: TimeInterval = 0
    private var failures = 0

    public init() {}

    public mutating func began(at time: TimeInterval) { attemptStarted = time }
    public mutating func ready() {
        attemptStarted = nil; failures = 0; retryAfter = 0
    }
    public mutating func failed(at time: TimeInterval) {
        attemptStarted = nil
        failures = min(failures + 1, 4)
        retryAfter = time + min(pow(2, Double(failures - 1)), 8)
    }
    public func canRetry(at time: TimeInterval) -> Bool { time >= retryAfter }
    public func setupExpired(at time: TimeInterval) -> Bool {
        attemptStarted.map { time - $0 >= 12 } ?? false
    }
}

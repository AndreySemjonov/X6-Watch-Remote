import Foundation

/// A cooperative deadline, also checked before camera I/O so suspended work
/// cannot start a capture merely because the timeout task has not run yet.
public enum CommandDeadline {
    @TaskLocal static var expiresAt: TimeInterval?

    public static func check() throws {
        try Task.checkCancellation()
        if let expiresAt, ProcessInfo.processInfo.systemUptime >= expiresAt {
            throw SessionError.deadlineExceeded
        }
    }

    @MainActor public static func run<Value: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        try check()
        let deadline = min(expiresAt ?? .infinity, ProcessInfo.processInfo.systemUptime + seconds)
        return try await $expiresAt.withValue(deadline) {
            try await withThrowingTaskGroup(of: Value.self) { group in
                group.addTask { try check(); return try await operation() }
                group.addTask {
                    let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
                    try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    throw SessionError.deadlineExceeded
                }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw CancellationError() }
                try check()
                return value
            }
        }
    }
}

/// Timing limits. A saving camera can answer STOP slowly and keep reporting
/// "recording" for a while, so capture replies and STOP get more time. Status
/// reads stay short. Nothing is ever re-sent; a longer wait is the only change.
public enum CommandTimeouts {
    public static let statusReply: TimeInterval = 4
    public static let captureReply: TimeInterval = 8
    /// Overall limit for commands that may send STOP (STOP, toggles, queued STOP).
    public static let stopCommand: TimeInterval = 25
    /// Overall limit for START and status commands.
    public static let command: TimeInterval = 15

    public static func reply(for command: CameraCommand) -> TimeInterval {
        command == .start || command == .stop ? captureReply : statusReply
    }
}

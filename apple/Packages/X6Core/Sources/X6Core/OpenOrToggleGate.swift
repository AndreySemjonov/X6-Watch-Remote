import Foundation

/// Immediate-foreground intents may run after activation has already reconnected
/// the camera. Freeze the connection present at activation for the first press.
/// Later presses use the live connection. No capture request is retained here.
public struct OpenOrToggleGate: Sendable {
    private var active = false
    private var activationPending = true
    private var activationConnection: UUID?
    private var hasActivated = false

    public init() {}

    public mutating func sceneChanged(active: Bool, connection: UUID?) {
        if active && !self.active {
            activationConnection = hasActivated ? connection : nil
            activationPending = true
            hasActivated = true
        }
        self.active = active
    }

    public mutating func takeConnection(current: UUID?) -> UUID? {
        if activationPending {
            activationPending = false
            guard let saved = activationConnection, saved == current else { return nil }
            return saved
        }
        return current
    }
}

/// Inactivity can be a temporary system interruption over the visible app.
/// Keep its last visibility until an active/background transition is observed.
public struct StatusNotificationPolicy: Sendable {
    public enum Phase { case active, inactive, background }
    public private(set) var visible = false
    private var commandBeganVisible = false

    public init() {}

    public mutating func sceneChanged(_ phase: Phase) {
        switch phase {
        case .active: visible = true
        case .inactive: break
        case .background: visible = false
        }
    }

    public mutating func beginCommand() { commandBeganVisible = visible }
    public mutating func endCommand() { commandBeganVisible = false }
    public var allowsStatusNotifications: Bool { !visible && !commandBeganVisible }
}

import AppIntents
import Foundation

// Compile these exact intent types into both apps so a shortcut authored on
// iPhone can resolve the same action in the installed Watch companion.
private enum X6IntentAction { case start, stop, toggle, status }

private struct RunOnWatchError: LocalizedError {
    var errorDescription: String? {
        "Run this shortcut on your Apple Watch. In shortcut details, enable Show on Apple Watch, then assign it to the Watch Action button."
    }
}

@MainActor private func executeX6Intent(_ action: X6IntentAction) async throws -> String {
    #if os(watchOS)
    let model = RemoteModel.shared
    model.log("intent_enter=\(action)")
    defer { model.log("intent_exit=\(action)") }
    switch action {
    case .start: return try await RemoteModel.shared.execute(.start)
    case .stop: return try await RemoteModel.shared.execute(.stop)
    case .toggle: return try await RemoteModel.shared.execute(.toggle)
    case .status: return try await RemoteModel.shared.execute(.status)
    }
    #else
    // The phone registers metadata only. Never forward or defer capture commands.
    throw RunOnWatchError()
    #endif
}

struct StartX6Recording: AppIntent {
    static var title: LocalizedStringResource = "Start X6 Recording"
    static var description = IntentDescription("Connect and explicitly start recording after reading the camera state.")
    static var supportedModes: IntentModes { .background }
    @MainActor func perform() async throws -> some IntentResult {
        _ = try await executeX6Intent(.start)
        return .result()
    }
}

/// Keep the original test intent type so existing shortcuts still resolve.
/// The system opens X6 before camera work, even if the camera is unavailable.
struct OpenX6AndStartRecording: AppIntent {
    static var title: LocalizedStringResource = "Open X6 or Toggle Recording"
    static var description = IntentDescription("Open X6 first. If already connected, toggle using fresh camera state. Otherwise reconnect only; press again after connection to control recording. Never queue recording from this action.")
    static var supportedModes: IntentModes { .foreground(.immediate) }
    @MainActor func perform() async throws -> some IntentResult {
        #if os(watchOS)
        _ = try await RemoteModel.shared.executeOpenOrToggle()
        #else
        throw RunOnWatchError()
        #endif
        return .result()
    }
}

struct StopX6Recording: AppIntent {
    static var title: LocalizedStringResource = "Stop X6 Recording"
    static var description = IntentDescription("Explicitly stop recording, or queue STOP if disconnected. Queued STOP requires app runtime to finish.")
    static var supportedModes: IntentModes { .background }
    @MainActor func perform() async throws -> some IntentResult {
        _ = try await executeX6Intent(.stop)
        return .result()
    }
}

struct ToggleX6Recording: AppIntent {
    static var title: LocalizedStringResource = "Toggle X6 Recording"
    static var description = IntentDescription("Toggle using fresh camera state. When disconnected, queue STOP only; never queue START.")
    static var supportedModes: IntentModes { .background }
    @MainActor func perform() async throws -> some IntentResult {
        _ = try await executeX6Intent(.toggle)
        return .result()
    }
}

struct ReadX6RecordingState: AppIntent {
    static var title: LocalizedStringResource = "Read X6 Recording State"
    static var supportedModes: IntentModes { .background }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await executeX6Intent(.status)
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

struct X6Shortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleX6Recording(), phrases: ["Toggle recording with \(.applicationName)"],
                    shortTitle: "Toggle X6 Recording", systemImageName: "record.circle")
        AppShortcut(intent: StopX6Recording(), phrases: ["Stop recording with \(.applicationName)"],
                    shortTitle: "Stop X6 Recording", systemImageName: "stop.fill")
        AppShortcut(intent: StartX6Recording(), phrases: ["Start recording with \(.applicationName)"],
                    shortTitle: "Start X6 Recording", systemImageName: "record.circle")
        AppShortcut(intent: OpenX6AndStartRecording(), phrases: ["Open \(.applicationName) or toggle recording"],
                    shortTitle: "Open or Toggle X6", systemImageName: "record.circle")
    }
}

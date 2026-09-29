import SwiftUI
import AppIntents
import WatchConnectivity

@main struct X6RemotePhoneApp: App {
    @StateObject private var inbox = LogInbox()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Section("Set up your Action button") {
                        Text("Open X6 Remote on your Apple Watch and connect your camera.")
                        Text("On this iPhone, create a shortcut with Open X6 or Toggle Recording. Enable Show on Apple Watch in the shortcut details.")
                        Text("On your Watch, go to Settings → Action Button → Shortcut and select it.")
                    }
                    Section("Camera control runs on your Watch") {
                        Text("This iPhone app makes the actions available in Shortcuts. Run them from your Watch; the phone does not connect to the camera.")
                        Text("Start explicitly starts recording. Toggle switches between START and STOP when connected. When disconnected, Toggle queues STOP only.")
                        Text("With SURFR, open X6 Remote on the Watch first and let the camera connect: its riding session then keeps it running and connected. Allow location when asked; nothing is stored.")
                    }
                    Section {
                        if inbox.files.isEmpty {
                            Text("No logs yet. On the Watch: X6 Remote → Settings → Diagnostics → Send logs to iPhone.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(inbox.files, id: \.self) { file in
                            ShareLink(item: file) {
                                Label(file.lastPathComponent, systemImage: "doc.text")
                            }
                        }
                        .onDelete { offsets in offsets.map { inbox.files[$0] }.forEach(inbox.delete) }
                    } header: {
                        Text("Watch logs")
                    } footer: {
                        Text("Tap a log to share it. Logs are also in Files → On My iPhone → X6 Remote, and in the Apple Devices app on a PC under File Sharing.")
                    }
                }
                .navigationTitle("X6 Remote")
                .refreshable { inbox.reload() }
            }
            .task { X6Shortcuts.updateAppShortcutParameters() }
        }
    }
}

/// Receives diagnostic files the Watch app sends and keeps them in Documents/Watch
/// logs, which the Files app and PC file sharing can see.
@MainActor final class LogInbox: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var files: [URL] = []

    nonisolated private static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Watch logs", isDirectory: true)
    }

    override init() {
        super.init()
        reload()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        files = urls.filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func delete(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
        reload()
    }

    /// The received file is deleted when this method returns, so move it here.
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let manager = FileManager.default
        let destination = Self.folder.appendingPathComponent(file.fileURL.lastPathComponent)
        try? manager.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? manager.removeItem(at: destination)
        try? manager.moveItem(at: file.fileURL, to: destination)
        Task { @MainActor in self.reload() }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}

import SwiftUI
import AppIntents

@main struct X6RemotePhoneApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Section("Set up your Action button") {
                        Text("Open X6 Remote on your Apple Watch and connect your camera.")
                        Text("On this iPhone, create a shortcut with Start X6 Recording or Toggle X6 Recording. Enable Show on Apple Watch in the shortcut details.")
                        Text("On your Watch, go to Settings → Action Button → Shortcut and select it.")
                    }
                    Section("Camera control runs on your Watch") {
                        Text("This iPhone app makes the actions available in Shortcuts. Run them from your Watch; the phone does not connect to the camera.")
                        Text("Start explicitly starts recording. Toggle switches between START and STOP when connected. When disconnected, Toggle queues STOP only.")
                        Text("With SURFR, open X6 Remote on the Watch first: its riding session keeps it running and connected. Allow location when asked; nothing is stored.")
                    }
                }
                .navigationTitle("X6 Remote")
            }
            .task { X6Shortcuts.updateAppShortcutParameters() }
        }
    }
}

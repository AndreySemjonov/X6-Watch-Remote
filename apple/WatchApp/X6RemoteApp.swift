import SwiftUI
import X6Core

@main struct X6RemoteApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = RemoteModel.shared

    var body: some Scene {
        WindowGroup {
            RemoteView(model: model)
                .onChange(of: scenePhase) { _, phase in
                    updateScene(phase)
                }
                .onAppear { updateScene(scenePhase) }
        }
        .backgroundTask(.bluetoothAlert) { await RemoteModel.shared.bluetoothAlert() }
    }

    private func updateScene(_ phase: ScenePhase) {
        switch phase {
        case .active: model.setScene(.active)
        case .inactive: model.setScene(.inactive)
        case .background: model.setScene(.background)
        @unknown default: model.setScene(.inactive)
        }
    }
}

struct RemoteView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: RemoteModel
    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = ProcessInfo.processInfo.systemUptime
                RidingScreen(control: control, connected: model.link.isReady,
                             duration: model.session.duration.text(state: model.session.state, at: now),
                             battery: model.telemetry.batteryText(at: now, connected: model.link.isReady),
                             storage: model.telemetry.storageText(at: now, connected: model.link.isReady),
                             workingTitle: workingTitle, live: scenePhase == .active,
                             waterLocked: model.waterLocked, riding: model.riding.isRunning,
                             setupMessage: !model.link.isReady && !model.session.pendingStop ? model.link.connection : nil,
                             onPress: { action in
                                 switch action {
                                 case .start: run(.start, touchFeedback: true)
                                 case .stop: run(.stop, touchFeedback: true)
                                 case .status: run(.status, touchFeedback: true)
                                 }
                             },
                             canLock: model.canEnableWaterLock, locking: model.waterLockChecking,
                             onLock: { model.enableWaterLock() },
                             doubleTap: model.doubleTapControl,
                             watchBattery: model.watchBattery) { settings }
                    .onChange(of: context.date) { _, _ in model.refreshWaterLockState() }
            }
            .navigationTitle("X6")
            .toolbarTitleDisplayMode(.inline)
            .alert("Water Lock is off", isPresented: $model.waterLockFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.riding.isRunning
                     ? "watchOS did not enable it. Use Control Centre → Water Lock."
                     : "Start the riding session first, or use Control Centre → Water Lock.")
            }
        }
    }
    private var workingTitle: String {
        switch model.activeAction {
        case .start: return "STARTING"
        case .stop: return "STOPPING"
        default: return "CHECKING CAMERA"
        }
    }
    private var control: RecordingControl {
        RecordingControl(state: model.session.state, ready: model.link.isReady,
                         busy: model.controlsBusy, pendingStop: model.session.pendingStop)
    }
    private func run(_ action: RemoteModel.Action, touchFeedback: Bool = false) {
        Task { _ = try? await model.execute(action, touchFeedback: touchFeedback) }
    }
    private var settings: some View {
        List {
            if let warning = model.budgetMessage {
                Text(warning).font(.caption2).foregroundStyle(.orange)
            }
            if model.session.pendingStop {
                Button("Cancel queued STOP") {
                    model.session.cancelPendingStop(); model.message = "Queued STOP cancelled"
                }.disabled(model.controlsBusy)
            }
            NavigationLink("Camera") { cameraSettings }
            NavigationLink("Riding session") { ridingSettings }
            Toggle("Touch feedback", isOn: $model.touchHaptics)
            Toggle("Double Tap starts/stops", isOn: $model.doubleTapControl)
            NavigationLink("Notifications") { notificationSettings }
            NavigationLink("Diagnostics") { diagnostics }
        }.navigationTitle("Settings")
    }

    private var cameraSettings: some View {
        List {
            Text(model.link.connection).font(.caption2)
            if !model.link.isReady {
                Button("Reconnect") { model.link.requestReconnect() }
                if !model.link.hasSavedCamera {
                    Button("Find camera") { model.link.scan() }
                    ForEach(model.link.nearby) { camera in
                        Button(camera.name) { model.link.select(camera.id) }
                    }
                }
            }
            Button("Forget camera", role: .destructive) { model.forgetCamera() }
                .disabled(model.controlsBusy)
        }.navigationTitle("Camera")
    }

    private var ridingSettings: some View {
        List {
            Text(model.ridingStatus).font(.caption2)
            if model.riding.isRunning {
                Button("End riding session", role: .destructive) { model.endRidingSession() }
            } else {
                Button("Start riding session") { model.startRidingSession() }
            }
            Toggle("Start when X6 opens", isOn: $model.autoRidingSession)
            Text("Keeps X6 Remote running and connected while SURFR is on screen. Uses location; nothing is stored. Ends after 4 hours without opening X6.")
                .font(.caption2).foregroundStyle(.secondary)
        }.navigationTitle("Riding")
    }

    private var notificationSettings: some View {
        List {
            Toggle("Status notifications", isOn: Binding(
                get: { model.statusNotifications },
                set: { enabled in Task { await model.setStatusNotifications(enabled) } }
            )).disabled(model.notificationSetupBusy)
            // Keep permission/error feedback after changing this setting.
            Text(model.notificationMessage).font(.caption2)
        }.navigationTitle("Notifications")
    }

    private var diagnostics: some View {
        List {
            Toggle("Detailed logging", isOn: $model.detailedLogging)
            NavigationLink("Last command report") {
                ScrollView { Text(model.commandReport).font(.system(size: 10, design: .monospaced)) }
            }
            NavigationLink("Last failed command") {
                ScrollView { Text(model.failureReport).font(.system(size: 10, design: .monospaced)) }
            }
            if model.detailedLogging {
                NavigationLink("Connection log") {
                    ScrollView { Text(model.connectionEvents.reversed().joined(separator: "\n")).font(.system(size: 10, design: .monospaced)) }
                }
                NavigationLink("Event log") {
                    ScrollView { Text(model.events.reversed().joined(separator: "\n")).font(.system(size: 10, design: .monospaced)) }
                }
            }
            Button("Check recording state") { run(.status) }.disabled(model.controlsBusy)
            Text(model.message).font(.caption2)
            Button("Read camera battery / SD") { model.readTelemetryIfDue(force: true) }
                .disabled(model.controlsBusy || !model.link.isReady || model.session.isRefreshing)
            Text(model.telemetryMessage).font(.caption2)
            Text(model.buildLabel).font(.caption2)
        }.navigationTitle("Diagnostics")
    }

}

/// All inputs are values; Xcode previews never initialize Bluetooth or the model.
private struct RidingScreen<Settings: View>: View {
    let control: RecordingControl
    let connected: Bool
    let duration: String
    let battery: String
    let storage: String
    var workingTitle = "CHECKING CAMERA"
    var live = true
    var waterLocked = false
    var riding = false
    var setupMessage: String?
    let onPress: (RecordingControl.Action) -> Void
    var canLock = false
    var locking = false
    var onLock: () -> Void = {}
    var doubleTap = true
    var watchBattery: Int?
    @ViewBuilder let settings: () -> Settings

    var body: some View {
        GeometryReader { geometry in
            // Fit the entire riding dashboard inside the safe content area.
            // There is deliberately no scrolling fallback: the Crown must not
            // move recording/connection information off screen during a ride.
            // Let available height drive sizing; the former width-based cap
            // left unused space above/below the content on the Ultra. Text
            // fits its own row horizontally instead of shrinking every row.
            let height: CGFloat = showsHint ? 220 : 192
            let scale = max(0.01, geometry.size.height / height)
            face
                .frame(width: geometry.size.width / scale, height: height)
                .scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
    private var accent: Color {
        switch control {
        case .stopped: return .green
        case .recording: return .red
        default: return .orange
        }
    }
    private var symbol: String {
        switch control {
        case .stopped: return "circle.fill"
        case .recording, .disconnected: return "stop.fill"
        case .unknown: return "arrow.clockwise"
        case .stopQueued, .working: return "hourglass"
        }
    }
    private var shownDuration: String {
        control == .working || control == .stopQueued || !connected ? "--:--" : duration
    }
    private var showsHint: Bool { [.unknown, .disconnected, .stopQueued].contains(control) }
    private var face: some View {
        // Normal: 40 + 28 + 56 + 56 + three 4-point gaps = 192.
        // Recovery adds a 24-point hint and one gap. Normal START/STOP use the
        // same geometry; recovery hints no longer reserve blank space on a ride.
        VStack(spacing: 4) {
            VStack(spacing: 2) {
                HStack(spacing: 5) {
                    Circle().fill(connected ? Color.green : Color.orange).frame(width: 8, height: 8)
                    Text(connected ? (live ? "CONNECTED" : "LAST OBSERVED") : "DISCONNECTED")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    if riding {
                        Image(systemName: "location.fill").font(.system(size: 11)).foregroundStyle(.green)
                            .accessibilityLabel("Riding session active")
                    }
                    if waterLocked { Image(systemName: "drop.fill").font(.system(size: 13)).foregroundStyle(.blue) }
                    if let watchBattery {
                        HStack(spacing: 2) {
                            Image(systemName: "applewatch").font(.system(size: 11))
                            Text("\(watchBattery)%").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        }
                        .foregroundStyle(watchBattery <= WatchBattery.lowPercent ? Color.orange : Color.white)
                        .lineLimit(1).fixedSize()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Watch battery \(watchBattery) percent")
                    }
                }
                HStack(spacing: 8) {
                    Text("CAM \(battery)")
                    if storage != "—" { Text("SD \(storage)") }
                }.font(.system(size: 15, weight: .medium)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityLabel(storage == "—" ? "Camera battery \(battery)" : "Camera battery \(battery), SD card free space \(storage)")
            }.frame(height: 40)
            Text(control == .working ? workingTitle : control.title)
                .font(.system(size: 24, weight: .bold))
                .lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(control == .stopped ? Color.white : accent)
                .frame(height: 28)
            Text(shownDuration)
                .font(.system(size: 50, weight: .bold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .accessibilityLabel("Recording duration \(shownDuration)")
                .frame(height: 56)
            HStack(spacing: 8) {
                Button {
                    if let action = control.action { onPress(action) }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: symbol).font(.system(size: 22, weight: .bold))
                            .foregroundStyle(control == .recording ? Color.white : accent)
                        Text(control.buttonTitle).font(.system(size: 26, weight: .bold))
                            .lineLimit(1).minimumScaleFactor(0.6).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56)
                    .background(control == .recording ? accent : accent.opacity(0.23),
                                in: RoundedRectangle(cornerRadius: 16))
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(RecordingPressStyle())
                // Double Tap presses this button only while X6 is on screen; the
                // button's own disabled states (busy, Water Lock) still apply.
                .handGestureShortcut(.primaryAction, isEnabled: doubleTap)
                .disabled(control.action == nil || waterLocked)
                .accessibilityLabel(control.buttonTitle)
                .accessibilityHint(waterLocked ? "Use the Action button while Water Lock is on." : control.hint)
                if canLock {
                    Button(action: onLock) {
                        Image(systemName: locking ? "hourglass" : "drop.fill").font(.system(size: 22))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 56)
                            .background(Color.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).disabled(locking)
                        .accessibilityLabel("Water Lock")
                        .accessibilityHint("Locks the touchscreen. Hold the Digital Crown to unlock.")
                }
                NavigationLink { settings() } label: {
                    Image(systemName: "gearshape.fill").font(.system(size: 22))
                        .frame(width: 44, height: 56)
                        .background(Color.gray.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).disabled(waterLocked).accessibilityLabel("Settings")
            }.frame(height: 56)
            if showsHint {
                Text(setupMessage ?? control.hint)
                .font(.system(size: 11)).foregroundStyle(.orange)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
            }
        }
    }
}

private struct RecordingPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .brightness(configuration.isPressed ? 0.08 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct RecordingDesignPreview: View {
    let control: RecordingControl
    let connected: Bool
    var locked = false
    var body: some View {
        NavigationStack {
            RidingScreen(control: control, connected: connected,
                         duration: control == .recording ? "00:23" : "00:00",
                         battery: connected ? "78%" : "—", storage: connected ? "42.0 GB" : "—",
                         workingTitle: "STARTING", waterLocked: locked, riding: connected,
                         onPress: { _ in }, canLock: connected && !locked, watchBattery: 64) { Text("Settings preview") }
                .navigationTitle("X6")
                .toolbarTitleDisplayMode(.inline)
        }
    }
}

#Preview("Stopped") { RecordingDesignPreview(control: .stopped, connected: true) }
#Preview("Tap accepted") { RecordingDesignPreview(control: .working, connected: true) }
#Preview("Recording") { RecordingDesignPreview(control: .recording, connected: true) }
#Preview("Water locked") { RecordingDesignPreview(control: .recording, connected: true, locked: true) }
#Preview("Disconnected") { RecordingDesignPreview(control: .disconnected, connected: false) }
#Preview("Stop queued") { RecordingDesignPreview(control: .stopQueued, connected: false) }
#Preview("Unknown") { RecordingDesignPreview(control: .unknown, connected: true) }

// Constrained content-area previews exercise the fixed layout without relying
// on the preview host's default Watch size or navigation-bar safe areas.
#Preview("Small content area") {
    RidingScreen(control: .unknown, connected: true, duration: "--:--",
                 battery: "100%", storage: "128.0 GB", onPress: { _ in }) { Text("Settings") }
        .frame(width: 172, height: 156)
}
#Preview("Discovery fits") {
    RidingScreen(control: .disconnected, connected: false, duration: "--:--",
                 battery: "—", storage: "—", setupMessage: "Choose camera in Settings → Camera",
                 onPress: { _ in }) { Text("Settings") }
        .frame(width: 184, height: 180)
}

#Preview("Ultra available space") {
    RidingScreen(control: .recording, connected: true, duration: "12:34",
                 battery: "39%", storage: "—", live: false,
                 onPress: { _ in }) { Text("Settings") }
        .frame(width: 205, height: 220)
}

// Longest header: DISCONNECTED plus riding, Water Lock and a 3-digit Watch battery.
#Preview("Header worst case") {
    RidingScreen(control: .disconnected, connected: false, duration: "--:--",
                 battery: "—", storage: "—", waterLocked: true, riding: true,
                 setupMessage: "Connecting…", onPress: { _ in }, watchBattery: 100) { Text("Settings") }
        .frame(width: 172, height: 156)
}

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
                RidingScreen(control: control,
                             face: RidingFace(control: control, workingTitle: workingTitle,
                                              connectionMessage: model.link.connection),
                             connected: model.link.isReady,
                             duration: model.session.duration.text(state: model.session.state, at: now),
                             cameraBattery: model.telemetry.batteryText(at: now, connected: model.link.isReady),
                             cameraBatteryLow: RidingFace.batteryLow(model.telemetry.batteryPercent(at: now, connected: model.link.isReady)),
                             storageLabel: model.telemetry.storageLabel(at: now, connected: model.link.isReady),
                             storage: model.telemetry.storageShortText(at: now, connected: model.link.isReady),
                             storageLow: model.telemetry.storageLow(at: now, connected: model.link.isReady),
                             watchBattery: model.watchBattery,
                             waterLocked: model.waterLocked, riding: model.riding.isRunning,
                             onPress: { action in
                                 switch action {
                                 case .start: run(.start, touchFeedback: true)
                                 case .stop: run(.stop, touchFeedback: true)
                                 case .status: run(.status, touchFeedback: true)
                                 }
                             },
                             canLock: model.canEnableWaterLock, locking: model.waterLockChecking,
                             onLock: { model.enableWaterLock() },
                             doubleTap: model.doubleTapControl) { settings }
                    .onChange(of: context.date) { _, _ in model.refreshWaterLockState() }
            }
            .navigationTitle("X6")
            .toolbarTitleDisplayMode(.inline)
            // The riding screen uses the full height; Settings pages keep their bars.
            .toolbar(.hidden, for: .navigationBar)
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
            // Every storage the camera reports; the strip shows the one recorded to.
            ForEach(model.telemetry.storageLines(at: ProcessInfo.processInfo.systemUptime,
                                                 connected: model.link.isReady), id: \.self) { line in
                Text(line).font(.caption2)
            }
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
/// Layout B: state-coloured background, one headline, the camera's recording time
/// as the largest element, and a three-value strip (camera, SD, Watch). Every size
/// derives from the available height, so larger Watches get larger text.
private struct RidingScreen<Settings: View>: View {
    @Environment(\.isLuminanceReduced) private var dimmed
    let control: RecordingControl
    let face: RidingFace
    let connected: Bool
    let duration: String
    var cameraBattery = "—"
    var cameraBatteryLow = false
    var storageLabel = "SD"
    var storage = "—"
    var storageLow = false
    var watchBattery: Int?
    var waterLocked = false
    var riding = false
    let onPress: (RecordingControl.Action) -> Void
    var canLock = false
    var locking = false
    var onLock: () -> Void = {}
    var doubleTap = true
    @ViewBuilder let settings: () -> Settings

    var body: some View {
        GeometryReader { geometry in
            // One unit is 1% of the usable height. No scrolling: the Crown must
            // never move recording information off screen during a ride.
            let unit = geometry.size.height / 100
            VStack(spacing: unit * 1.5) {
                headline(unit)
                Text(shownDuration)
                    .font(.system(size: unit * 27, weight: .bold, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                    .foregroundStyle(.white)
                    .frame(height: unit * 28)
                    .accessibilityLabel("Recording duration \(shownDuration)")
                strip(unit)
                if let hint = face.hint {
                    Text(hint)
                        .font(.system(size: max(13, unit * 6), weight: .medium))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
                buttons(unit).opacity(dimmed ? 0.35 : 1)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(tint.ignoresSafeArea())
    }

    private var tint: Color {
        let strength = dimmed ? 0.14 : 0.28
        switch face.tone {
        case .recording: return Color.red.opacity(strength)
        case .attention: return Color.orange.opacity(strength)
        case .neutral: return Color.black
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

    private func headline(_ unit: CGFloat) -> some View {
        HStack(spacing: unit * 2) {
            Text(face.headline)
                .font(.system(size: unit * 10, weight: .heavy))
                .foregroundStyle(face.tone == .recording ? Color.red : (face.tone == .attention ? Color.orange : Color.white))
                .lineLimit(1).minimumScaleFactor(0.6)
            if riding {
                Image(systemName: "location.fill").font(.system(size: unit * 6))
                    .foregroundStyle(.green).accessibilityLabel("Riding session active")
            }
            if waterLocked {
                Image(systemName: "drop.fill").font(.system(size: unit * 7))
                    .foregroundStyle(.blue).accessibilityLabel("Water Lock on")
            }
        }
        .frame(height: unit * 12)
    }

    private func strip(_ unit: CGFloat) -> some View {
        HStack(spacing: unit * 2) {
            value("CAM", cameraBattery, low: cameraBatteryLow, unit)
                .accessibilityLabel("Camera battery \(cameraBattery)")
            value(storageLabel, storage, low: storageLow, unit)
                .accessibilityLabel("\(storageLabel == "INT" ? "Internal storage" : "SD card") free space \(storage)")
            value("WATCH", watchBattery.map { "\($0)%" } ?? "—",
                  low: watchBattery.map { $0 <= WatchBattery.lowPercent } ?? false, unit)
                .accessibilityLabel("Watch battery \(watchBattery.map { "\($0) percent" } ?? "unknown")")
        }
        .opacity(dimmed ? 0.6 : 1)
    }

    private func value(_ label: String, _ text: String, low: Bool, _ unit: CGFloat) -> some View {
        VStack(spacing: 0) {
            Text(label).font(.system(size: max(11, unit * 5), weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text(text).font(.system(size: unit * 10, weight: .bold)).monospacedDigit()
                .foregroundStyle(low ? Color.orange : Color.white)
                .lineLimit(1).minimumScaleFactor(0.55)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
    }

    private func buttons(_ unit: CGFloat) -> some View {
        let height = unit * 22
        return HStack(spacing: unit * 2.5) {
            Button {
                if let action = control.action { onPress(action) }
            } label: {
                HStack(spacing: unit * 2.5) {
                    Image(systemName: symbol).font(.system(size: unit * 9, weight: .bold))
                        .foregroundStyle(control == .recording ? Color.white : accent)
                    Text(control.buttonTitle).font(.system(size: unit * 11, weight: .bold))
                        .lineLimit(1).minimumScaleFactor(0.5).foregroundStyle(.white)
                }
                .padding(.horizontal, unit * 3)
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .background(control == .recording ? accent : accent.opacity(0.23),
                            in: RoundedRectangle(cornerRadius: unit * 7))
                .contentShape(RoundedRectangle(cornerRadius: unit * 7))
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
                    Image(systemName: locking ? "hourglass" : "drop.fill").font(.system(size: unit * 9))
                        .foregroundStyle(.white)
                        .frame(width: unit * 18, height: height)
                        .background(Color.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: unit * 5))
                }.buttonStyle(.plain).disabled(locking)
                    .accessibilityLabel("Water Lock")
                    .accessibilityHint("Locks the touchscreen. Hold the Digital Crown to unlock.")
            }
            NavigationLink { settings() } label: {
                Image(systemName: "gearshape.fill").font(.system(size: unit * 9))
                    .frame(width: unit * 18, height: height)
                    .background(Color.gray.opacity(0.25), in: RoundedRectangle(cornerRadius: unit * 5))
            }.buttonStyle(.plain).disabled(waterLocked).accessibilityLabel("Settings")
        }
        .frame(height: height)
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
            RidingScreen(control: control,
                         face: RidingFace(control: control, workingTitle: "STARTING"),
                         connected: connected,
                         duration: control == .recording ? "12:34" : "00:00",
                         cameraBattery: connected ? "78%" : "—", storage: connected ? "42G" : "—",
                         watchBattery: 30, waterLocked: locked, riding: true,
                         onPress: { _ in }, canLock: connected && !locked) { Text("Settings preview") }
                .toolbar(.hidden, for: .navigationBar)
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

// Smallest Watch content area with the longest texts: everything must still fit.
#Preview("Small content area, worst case") {
    RidingScreen(control: .disconnected,
                 face: RidingFace(control: .disconnected, workingTitle: "",
                                  connectionMessage: "Choose camera in Settings → Camera"),
                 connected: false, duration: "--:--", cameraBattery: "100%", cameraBatteryLow: true,
                 storage: "No card", storageLow: true, watchBattery: 100, waterLocked: true, riding: true,
                 onPress: { _ in }) { Text("Settings") }
        .frame(width: 162, height: 170)
}

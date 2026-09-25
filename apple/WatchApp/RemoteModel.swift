import Foundation
import Combine
import WatchKit
import UserNotifications
import X6Core

@MainActor final class RemoteModel: ObservableObject {
    static let shared = RemoteModel()
    let link = BluetoothCamera()
    let session: RecordingSession
    let riding = RidingSession()
    private var ridingPolicy = RidingSessionPolicy()
    @Published var message = "Keep your X6 nearby and switched on"
    // Not @Published: a log line must not redraw the riding screen. Diagnostics
    // views read these whenever the settings content is re-rendered.
    private(set) var events: [String] = []
    private(set) var connectionEvents: [String] = []
    /// Always kept (in memory only) as the command report's lead-in context.
    private var recentEvents: [String] = []
    @Published private(set) var budgetMessage: String?
    @Published private(set) var statusNotifications = UserDefaults.standard.bool(forKey: "statusNotifications")
    @Published private(set) var notificationSetupBusy = false
    @Published private(set) var notificationMessage = "Optional alerts while another app is visible."
    private var noticeTracker = CameraNoticeTracker()
    private var recoveryFeedback = AutomaticFeedbackGate()
    private var notificationPolicy = StatusNotificationPolicy()
    private let quietForegroundNotifications = QuietForegroundNotifications()
    private var commandTrace: CommandTrace
    var commandReport: String { commandTrace.report }
    var failureReport: String { commandTrace.lastFailureReport }
    static let diagnosticRevision = "install-check-20"
    @Published private(set) var telemetry = CameraTelemetryDisplay()
    @Published private(set) var telemetryMessage = "Camera readings have not arrived yet."
    @Published private(set) var waterLocked = false
    @Published private(set) var waterLockChecking = false
    @Published private(set) var watchBattery: Int?
    @Published var waterLockFailed = false
    /// watchOS enables Water Lock only for a foreground app with an active
    /// workout or location session; the riding session provides the latter.
    var canEnableWaterLock: Bool { riding.isRunning && !waterLocked }
    @Published private(set) var activeAction: Action?
    @Published var touchHaptics = UserDefaults.standard.object(forKey: "touchHaptics") as? Bool ?? true {
        didSet { UserDefaults.standard.set(touchHaptics, forKey: "touchHaptics") }
    }
    /// Detailed logs are off by default. The last command report
    /// is always kept; it is written once per command, not per log line.
    @Published var detailedLogging = UserDefaults.standard.bool(forKey: "detailedLogging") {
        didSet {
            UserDefaults.standard.set(detailedLogging, forKey: "detailedLogging")
            if !detailedLogging {
                events = []; connectionEvents = []
                try? logFile?.close(); logFile = nil
            }
            log("detailed_logging=\(detailedLogging)")
        }
    }
    /// Double Tap (Watch Ultra 2 / Series 9+) presses the visible START/STOP button.
    @Published var doubleTapControl = UserDefaults.standard.object(forKey: "doubleTapControl") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(doubleTapControl, forKey: "doubleTapControl")
            log("double_tap_control=\(doubleTapControl)")
        }
    }
    @Published var autoRidingSession = UserDefaults.standard.object(forKey: "autoRidingSession") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoRidingSession, forKey: "autoRidingSession")
            log("auto_riding_session=\(autoRidingSession)")
        }
    }
    private var telemetryTask: Task<Void, Never>?
    private var lastTelemetryAttempt: TimeInterval?
    private var pollWake: Task<Void, Never>?
    private var logFile: FileHandle?
    private var logSize = 0
    private var lastReportSave: TimeInterval = -.infinity
    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    var buildLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build)) / \(Self.diagnosticRevision)"
    }
    private var foreground = false
    private var openOrToggleGate = OpenOrToggleGate()
    @Published private var intentUsers = 0
    var controlsBusy: Bool { intentUsers > 0 || session.commandBusy }
    private var budgetExhausted = false
    private var operationTask: Task<Void, Never>?
    private var operationID: UUID?
    private var refreshTask: Task<Void, Never>?
    private let logURL: URL
    private let commandReportURL: URL
    private let failureReportURL: URL

    private init() {
        session = RecordingSession(link: link)
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logURL = directory.appendingPathComponent("x6-diagnostics.txt")
        commandReportURL = directory.appendingPathComponent("x6-last-command.txt")
        failureReportURL = directory.appendingPathComponent("x6-last-failure.txt")
        commandTrace = CommandTrace(
            lastReport: (try? String(contentsOf: commandReportURL, encoding: .utf8)) ?? "No command recorded yet.",
            lastFailureReport: (try? String(contentsOf: failureReportURL, encoding: .utf8)) ?? "No failed command recorded yet.")
        // Keep the focused trace across process relaunches, using the existing
        // bounded local diagnostic file. No camera payloads enter this view.
        if detailedLogging, let previous = try? String(contentsOf: logURL, encoding: .utf8) {
            connectionEvents = Array(previous.components(separatedBy: "\n")
                .filter { $0.contains(" [connection] ") }.suffix(120))
        }
        UNUserNotificationCenter.current().delegate = quietForegroundNotifications
        link.log = { [weak self] in self?.log($0) }
        link.changed = { [weak self] in self?.objectWillChange.send() }
        link.lost = { [weak self] in
            guard let self else { return }
            self.session.connectionLost()
            self.telemetryTask?.cancel()
            self.telemetry.clear(); self.lastTelemetryAttempt = nil
            self.postNotice(self.noticeTracker.connectionChanged(false))
        }
        link.statusChanged = { [weak self] in
            guard let self else { return }
            self.session.invalidate()
            // A capture command normally invalidates state before confirming it.
            // Report unsolicited invalidation only outside that command, and
            // read fresh state now instead of waiting for the next poll.
            if !self.session.busy {
                self.postNotice(self.noticeTracker.observed(.unknown))
                self.pollSoon()
            }
        }
        link.budgetWarning = { [weak self] exhausted in
            guard let self else { return }
            self.budgetExhausted = exhausted
            self.budgetMessage = exhausted ? "Background Bluetooth budget exhausted. Open app to resume." : "Background Bluetooth budget nearly exhausted."
            self.log(self.budgetMessage!)
            self.log("[connection] bluetooth_budget exhausted=\(exhausted)")
            self.postNotice(.budget)
            self.updatePolicy()
        }
        link.ready = { [weak self] in self?.handleReady() }
        link.batteryChanged = { [weak self] percent in
            self?.telemetry.observeBattery(percent, at: ProcessInfo.processInfo.systemUptime)
        }
        session.diagnostic = { [weak self] in self?.log($0) }
        session.changed = { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
            if !self.session.busy, self.session.state != .unknown {
                self.postNotice(self.noticeTracker.observed(self.session.state))
            }
        }
        session.confirmed = { [weak self] result in
            self?.message = Self.description(result)
            self?.log("confirmed=\(result.rawValue)")
            if let self { self.postNotice(self.noticeTracker.confirmed(result)) }
            // Distinct system patterns; delivery while locked/background needs hardware validation.
            self?.log("haptic_requested=\(result.rawValue) source=confirmation foreground=\(self?.foreground ?? false)")
            switch result {
            case .recording: WKInterfaceDevice.current().play(.start)
            case .stopped: WKInterfaceDevice.current().play(.stop)
            case .stopQueued: WKInterfaceDevice.current().play(.retry)
            }
        }
        riding.log = { [weak self] in self?.log($0) }
        riding.changed = { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
            self.updatePolicy()
            self.updateRefreshLoop()
        }
        log("[connection] process_started build=\(buildLabel) session=\(UUID().uuidString) auto_riding_session=\(autoRidingSession)")
        link.permitConnection = true
        link.permitScan = false
        log("app_started; build=\(buildLabel); detailed_logging=\(detailedLogging); status_notifications=\(statusNotifications); pending_stop_not_persisted")
    }

    static func description(_ result: ControlResult) -> String {
        switch result {
        case .recording: return "Recording confirmed"
        case .stopped: return "Stopped confirmed"
        case .stopQueued: return "STOP queued — camera may still be recording"
        }
    }

    func setStatusNotifications(_ enabled: Bool) async {
        guard !notificationSetupBusy else { return }
        notificationSetupBusy = true
        defer { notificationSetupBusy = false }
        if enabled {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
                statusNotifications = granted
                notificationMessage = granted
                    ? "Enabled. Notification visibility follows Watch settings and Focus."
                    : "Notifications are not allowed. Enable X6 Remote notifications in Watch settings."
            } catch {
                statusNotifications = false
                notificationMessage = "Could not request notifications: \(error.localizedDescription)"
            }
        } else {
            statusNotifications = false
            notificationMessage = "Status notifications off."
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["x6-status"])
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["x6-status"])
        }
        UserDefaults.standard.set(statusNotifications, forKey: "statusNotifications")
        log("status_notifications=\(statusNotifications)")
    }

    private func postNotice(_ notice: CameraNotice?) {
        guard let notice, statusNotifications, notificationPolicy.allowsStatusNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.subtitle = "Observed at \(Date().formatted(date: .omitted, time: .standard))"
        content.body = notice.body
        content.threadIdentifier = "x6-status"
        // No actions, dialogs, automatic app launch, or added notification sound.
        // Notifications are best-effort feedback, never part of the command's
        // completion path. The system's completion callback has no time bound.
        // Waiting for it held intentUsers/operationTask open and could block STOP.
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ["x6-status"])
        log("status_notification_requested=\(notice.rawValue)")
        center.add(UNNotificationRequest(identifier: "x6-status", content: content, trigger: nil)) { [weak self] error in
            Task { @MainActor [weak self] in
                if let error { self?.log("status_notification_error \(error.localizedDescription)") }
                else { self?.log("status_notification_submitted=\(notice.rawValue)") }
            }
        }
    }

    func log(_ text: String) {
        let line = "\(Self.timestamp.string(from: Date())) \(text)"
        recentEvents.append(line)
        if recentEvents.count > 20 { recentEvents.removeFirst(recentEvents.count - 20) }
        commandTrace.append(line)
        // Persist an in-progress command at most once per second; begin, finish
        // and errors save immediately.
        if commandTrace.isActive { saveCommandReport(throttled: true) }
        guard detailedLogging else { return }
        events.append(line); if events.count > 80 { events.removeFirst(events.count - 80) }
        if text.hasPrefix("[connection] ") {
            connectionEvents.append(line)
            if connectionEvents.count > 120 { connectionEvents.removeFirst(connectionEvents.count - 120) }
        }
        appendToLogFile(line)
    }

    /// Bounded local diagnostics, no network/analytics. Export through Xcode app
    /// container. At 512 KB the file becomes x6-diagnostics-previous.txt.
    private func appendToLogFile(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if logFile == nil { openLogFile() }
        if logSize + data.count > 512_000 {
            try? logFile?.close(); logFile = nil
            let previous = logURL.deletingLastPathComponent().appendingPathComponent("x6-diagnostics-previous.txt")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: logURL, to: previous)
            openLogFile()
        }
        guard let logFile else { return }
        do { try logFile.write(contentsOf: data); logSize += data.count }
        catch { try? logFile.close(); self.logFile = nil }
    }

    private func openLogFile() {
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        logFile = try? FileHandle(forWritingTo: logURL)
        logSize = Int((try? logFile?.seekToEnd()) ?? 0)
    }

    private func saveCommandReport(throttled: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        if throttled && now - lastReportSave < 1 { return }
        lastReportSave = now
        try? commandTrace.report.write(to: commandReportURL, atomically: true, encoding: .utf8)
    }

    func setScene(_ phase: StatusNotificationPolicy.Phase) {
        log("[connection] scene=\(phase) ready=\(link.isReady) busy=\(session.busy) intent_users=\(intentUsers)")
        refreshWaterLockState()
        let wasVisible = notificationPolicy.visible
        notificationPolicy.sceneChanged(phase)
        if notificationPolicy.visible {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: ["x6-status"])
            center.removeDeliveredNotifications(withIdentifiers: ["x6-status"])
        }
        // Cold launch or return from background; a wrist raise is not an open.
        // Location sessions may only start while active, which this is.
        if !wasVisible && notificationPolicy.visible {
            let decision = ridingPolicy.opened(enabled: autoRidingSession, at: Date().timeIntervalSinceReferenceDate)
            // Also retry a wanted session that permission or the OS stopped.
            if decision == .start || (ridingPolicy.wanted && !riding.isRunning) { riding.start() }
        }
        setForeground(phase == .active)
    }

    // MARK: Riding session

    func startRidingSession() {
        let decision = ridingPolicy.userStarted(at: Date().timeIntervalSinceReferenceDate)
        if decision == .start || !riding.isRunning { riding.start() }
    }

    func endRidingSession() {
        _ = ridingPolicy.userEnded()
        riding.stop()
    }

    var ridingStatus: String {
        switch riding.state {
        case .off: return "Off. Opening X6 Remote starts it when automatic start is on."
        case .waitingForPermission: return "Waiting for location permission."
        case .denied: return "Location is not allowed. Enable X6 Remote in Watch Settings → Privacy & Security → Location Services."
        case .running:
            let remaining = ridingPolicy.remaining(at: Date().timeIntervalSinceReferenceDate) ?? 0
            let minutes = Int(remaining / 60)
            return "Active. Ends in \(minutes / 60)h \(minutes % 60)m unless X6 Remote is opened again."
        }
    }

    private func checkRidingDeadline() {
        guard ridingPolicy.check(at: Date().timeIntervalSinceReferenceDate) == .stop else { return }
        log("riding_session_expired hours=\(RidingSessionPolicy.maximumDuration / 3600)")
        riding.stop()
    }

    // MARK: Status polling

    private var pollInterval: TimeInterval? {
        StatusPollingSchedule.interval(active: foreground, frontmost: notificationPolicy.visible, riding: riding.isRunning)
    }

    private func setForeground(_ value: Bool) {
        openOrToggleGate.sceneChanged(active: value, connection: link.connectionID)
        foreground = value; log("foreground=\(value)")
        if value { budgetExhausted = false; budgetMessage = nil }
        updatePolicy()
        if !value { telemetryTask?.cancel() }
        updateRefreshLoop()
        // Show fresh state on a wrist raise instead of the slower passive sample.
        if value { pollSoon() }
    }

    /// Wrist-down frontmost and a background riding session keep a slower
    /// read-only cadence. Otherwise the loop ends; it never grants runtime.
    private func updateRefreshLoop() {
        log("[connection] polling_policy active=\(foreground) frontmost=\(notificationPolicy.visible) riding=\(riding.isRunning) interval=\(pollInterval.map { String(Int($0)) } ?? "off") telemetry=\(foreground)")
        guard pollInterval != nil else {
            session.invalidate()
            refreshTask?.cancel(); refreshTask = nil
            return
        }
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.checkRidingDeadline()
                // A failed connect/setup callback has no background timer.
                // Retry while active or riding, including after a long gap.
                if self.foreground || self.riding.isRunning { self.link.requestReconnect() }
                if self.pollInterval != nil, self.link.isReady, !self.session.busy, self.intentUsers == 0 {
                    do {
                        self.log("[connection] status_poll_begin active=\(self.foreground)")
                        let snapshot = try await self.session.refresh()
                        self.log("[connection] status_poll_ok active=\(self.foreground)")
                        self.postNotice(self.noticeTracker.observed(snapshot.recording))
                        self.readTelemetryIfDue()
                    }
                    catch {
                        self.log("[connection] status_poll_failed active=\(self.foreground) error=\(String(reflecting: error))")
                        self.postNotice(self.noticeTracker.observed(.unknown))
                    }
                }
                let interval = self.pollInterval ?? StatusPollingSchedule.passiveInterval
                let wait = Task { _ = try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
                self.pollWake = wait
                await withTaskCancellationHandler { await wait.value } onCancel: { wait.cancel() }
                if self.pollWake == wait { self.pollWake = nil }
            }
        }
    }

    /// Ends the current wait so the loop reads camera state promptly.
    private func pollSoon() { pollWake?.cancel() }

    /// Optional telemetry is foreground-only and uses the same transport gate.
    /// A user command cancels this task before waiting for the gate to release.
    func readTelemetryIfDue(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard foreground, link.isReady, !session.busy, intentUsers == 0, telemetryTask == nil,
              force || now - (lastTelemetryAttempt ?? -.infinity) >= 30 else { return }
        lastTelemetryAttempt = now
        telemetryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.telemetryTask = nil }
            do {
                let reading = try await self.session.refreshTelemetry()
                self.telemetry.observe(reading, at: ProcessInfo.processInfo.systemUptime)
                self.telemetryMessage = "Read camera battery and SD card. A dash means unavailable."
                self.log("telemetry battery=\(reading.batteryPercent.map(String.init) ?? "nil") free=\(reading.freeBytes.map(String.init) ?? "nil") total=\(reading.totalBytes.map(String.init) ?? "nil") card=\(reading.cardState.map(String.init) ?? "nil")")
            } catch {
                if !Task.isCancelled {
                    self.telemetryMessage = "Camera readings could not be refreshed. See Diagnostics for details."
                    self.log("telemetry_read_failed \(String(reflecting: error))")
                }
                // No haptic, capture-state change or command-error notification.
            }
        }
    }

    func refreshWaterLockState() {
        let value = WKInterfaceDevice.current().isWaterLockEnabled
        if value != waterLocked { waterLocked = value; log("water_lock=\(value)") }
        refreshWatchBattery()
    }

    /// Called on the visible 1-second tick; publishes only when the percent changes.
    func refreshWatchBattery() {
        let device = WKInterfaceDevice.current()
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let value = WatchBattery.percent(level: device.batteryLevel)
        if value != watchBattery { watchBattery = value }
    }

    func enableWaterLock() {
        refreshWaterLockState()
        guard foreground, !waterLocked, !waterLockChecking else { return }
        let device = WKInterfaceDevice.current()
        log("water_lock_requested riding=\(riding.isRunning) rating=\(device.waterResistanceRating.rawValue)")
        guard riding.isRunning else { waterLockFailed = true; return }
        waterLockChecking = true
        device.enableWaterLock()
        // The API has no result; confirm through the actual system flag.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self else { return }
            self.refreshWaterLockState()
            self.waterLockChecking = false
            self.log("water_lock_request_result enabled=\(self.waterLocked)")
            if !self.waterLocked, self.foreground { self.waterLockFailed = true }
        }
    }

    private func updatePolicy() {
        // A running riding session keeps the process alive, so it may also
        // replace stalled attempts. Without it, background connection relies on
        // the limited Bluetooth wake budget.
        link.permitRecovery = foreground || intentUsers > 0 || riding.isRunning
        link.permitScan = foreground
        if !foreground { link.stopScan() }
        link.permitConnection = notificationPolicy.visible || intentUsers > 0 || riding.isRunning || !budgetExhausted
        log("[connection] connection_policy allowed=\(link.permitConnection) scan=\(link.permitScan) riding=\(riding.isRunning) budget_exhausted=\(budgetExhausted)")
        if link.permitConnection { link.requestReconnect() }
        else {
            operationTask?.cancel(); operationTask = nil
            operationID = nil
            link.suspendConnection(reason: "background_policy")
            if session.pendingStop { message = "STOP queued — reopen app to reconnect" }
        }
    }

    private func handleReady() {
        postNotice(noticeTracker.connectionChanged(true))
        guard operationTask == nil else { return }
        let id = UUID(); operationID = id
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.operationID == id { self.operationTask = nil; self.operationID = nil }
            }
            // A disconnect can finish an older command just after the ready callback.
            do {
                // May send a queued STOP, so it gets the STOP limit.
                try await CommandDeadline.run(seconds: CommandTimeouts.stopCommand) {
                    while self.session.busy {
                        try CommandDeadline.check()
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    try await self.session.connectionReady()
                }
            }
            catch { self.show(error, source: "connection_ready") }
        }
    }

    func show(_ error: Error, source: String = "user_action") {
        message = error.localizedDescription; log("operation_error \(String(reflecting: error)) source=\(source)")
        if commandTrace.isActive { saveCommandReport() }
        if source != "user_action", !recoveryFeedback.allow(at: ProcessInfo.processInfo.systemUptime) {
            log("automatic_failure_feedback_suppressed source=\(source)")
            return
        }
        postNotice(.failed)
        log("haptic_requested=failure source=\(source) foreground=\(foreground)")
        WKInterfaceDevice.current().play(.failure)
    }

    enum Action { case start, stop, toggle, status, connectedToggle }

    func executeOpenOrToggle() async throws -> String {
        // Immediate foreground may already have initiated reconnection. Use the
        // activation snapshot for its first press so it cannot turn into START.
        let connection = openOrToggleGate.takeConnection(current: link.connectionID)
        log("intent_enter=openOrToggle route=\(connection == nil ? "openOnly" : "connectedToggle") foreground=\(foreground)")
        defer { log("intent_exit=openOrToggle") }
        guard let connection else { return openAndReconnectOnly() }
        return try await execute(.connectedToggle, expectedConnection: connection)
    }

    private func openAndReconnectOnly() -> String {
        // No wait, START, STOP, or queued capture. Foreground recovery continues
        // independently after this Shortcut has completed.
        updatePolicy()
        message = link.isReady ? "Connected — press again to control recording" : "Reconnecting — press again once connected"
        log("open_only ready=\(link.isReady); no_capture_queued")
        return message
    }

    /// A bounded App Intent uses the same actor/connection as the visible app.
    func execute(_ action: Action, touchFeedback: Bool = false, expectedConnection: UUID? = nil) async throws -> String {
        let started = ProcessInfo.processInfo.systemUptime
        log("user_action_enter=\(action) ready=\(link.isReady) foreground=\(foreground) refreshing=\(session.isRefreshing) pending_stop=\(session.pendingStop)")
        guard !controlsBusy else {
            log("user_action_rejected=\(action) intent_users=\(intentUsers) command_busy=\(session.commandBusy)")
            commandTrace.recordFailure(failureSummary(action, SessionError.busy, elapsed: 0,
                                                      stage: "rejected: previous command still running"),
                                       context: recentEvents)
            saveFailureReport()
            throw SessionError.busy
        }
        telemetryTask?.cancel()
        session.clearCaptureStage()
        var failure: Error?
        if touchFeedback, foreground, !waterLocked, touchHaptics {
            log("haptic_requested=click source=touch_accepted")
            WKInterfaceDevice.current().play(.click)
        }
        activeAction = action
        commandTrace.begin(context: recentEvents)
        log("command_report_build=\(buildLabel)")
        saveCommandReport()
        notificationPolicy.beginCommand()
        intentUsers += 1
        defer {
            intentUsers -= 1
            activeAction = nil
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            log("user_action_finished=\(action) elapsed=\(elapsed)")
            updatePolicy()
            if let failure {
                commandTrace.finish(failureSummary: failureSummary(action, failure, elapsed: elapsed,
                                                                   stage: session.captureStage ?? "before START/STOP was sent"))
                saveFailureReport()
            } else { commandTrace.finish() }
            saveCommandReport()
            notificationPolicy.endCommand()
        }
        updatePolicy()
        log("user_action=\(action)")
        // Anything that may send STOP gets the longer limit; START stays strict.
        let limit = action == .start || action == .status ? CommandTimeouts.command : CommandTimeouts.stopCommand
        do {
            return try await CommandDeadline.run(seconds: limit) {
                try await self.executeReserved(action, expectedConnection: expectedConnection)
            }
        } catch {
            failure = error
            show(error)
            throw error
        }
    }

    /// First lines of the kept failed-command report, readable on the Watch.
    private func failureSummary(_ action: Action, _ error: Error, elapsed: TimeInterval, stage: String) -> String {
        let time = Date().formatted(date: .abbreviated, time: .standard)
        return """
        FAILED \(time)
        Action: \(action) · \(stage) · \(String(format: "%.1f", elapsed)) s
        \(error.localizedDescription)
        \(String(reflecting: error)) · \(buildLabel)
        """
    }

    private func saveFailureReport() {
        try? commandTrace.lastFailureReport.write(to: failureReportURL, atomically: true, encoding: .utf8)
    }

    private func executeReserved(_ action: Action, expectedConnection: UUID?) async throws -> String {
        // A tap during a routine read waits for that bounded BLE request.
        // Reserve the user-command slot first, so polling cannot jump ahead
        // and a second tap cannot queue another capture command.
        while session.isRefreshing {
            try CommandDeadline.check()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try CommandDeadline.check()
        // Explicit START/status may wait for an immediate connection, but aren't queued.
        if action == .start || action == .status {
            try await waitForConnection(seconds: 10)
            while session.busy {
                try CommandDeadline.check()
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        if action == .status {
            let status = try await session.refresh()
            let text = "Camera: \(status.recording.rawValue)"
            message = text
            return text
        }
        let result: ControlResult
        switch action {
        case .start: result = try await session.start()
        case .stop: result = try await session.stop()
        case .toggle: result = try await session.toggle()
        case .connectedToggle:
            guard let expectedConnection else { return openAndReconnectOnly() }
            guard let confirmed = try await session.toggleConnectedOnly(isCurrentConnection: {
                self.link.connectionID == expectedConnection
            }) else { return openAndReconnectOnly() }
            result = confirmed
        case .status: fatalError("Handled above")
        }
        if result == .stopQueued {
            log("user_action_waiting_for_queued_stop=\(action) limit_seconds=10")
            // Leave the queue intact when this bounded opportunity ends.
            // watchOS may suspend us afterwards; this is not an indefinite runtime grant.
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline && (session.pendingStop || session.busy) {
                try CommandDeadline.check()
                link.requestReconnect()
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if !session.pendingStop && !session.busy && session.state == .stopped {
                return Self.description(.stopped)
            }
            if !session.pendingStop { throw SessionError.notConfirmed }
            message = Self.description(.stopQueued)
            return message
        }
        return Self.description(result)
    }

    private func waitForConnection(seconds: TimeInterval) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !link.isReady && ProcessInfo.processInfo.systemUptime < deadline {
            try CommandDeadline.check()
            link.requestReconnect()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard link.isReady else { throw LinkError.unavailable }
    }

    func bluetoothAlert() async {
        log("background_bluetooth_alert")
        // Keep useful pending work attached to the OS's cancellable runtime grant.
        // Delegate delivery can follow the alert callback. Wait briefly for readiness;
        // do not send repeated BLE status queries or ACK heartbeat traffic.
        let deadline = Date().addingTimeInterval(2)
        while session.pendingStop && !link.isReady && Date() < deadline {
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
        }
        if let task = operationTask {
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        }
        if session.pendingStop, link.isReady, !session.busy {
            do {
                try await CommandDeadline.run(seconds: CommandTimeouts.stopCommand) { try await self.session.connectionReady() }
            } catch { show(error, source: "bluetooth_alert") }
        }
    }

    func forgetCamera() {
        guard !controlsBusy else { return }
        session.cancelPendingStop(); link.forget()
        message = "Camera forgotten. Scan to select again."
    }
}

/// Also silence a previously submitted notice delivered after the app opens.
/// This delegate controls our notifications, not Shortcuts system error alerts.
private final class QuietForegroundNotifications: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }
}

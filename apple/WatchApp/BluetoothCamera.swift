import Foundation
import CoreBluetooth
import X6Core

enum LinkError: Error, LocalizedError {
    case unavailable, timeout, cancelled, missingServices, writeFailed, telemetryWriteSize
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Camera is not connected."
        case .timeout: return "Camera reply timed out; recording state is unknown."
        case .cancelled: return "Bluetooth operation cancelled."
        case .missingServices: return "The camera did not expose the expected X6 services."
        case .writeFailed: return "Bluetooth write failed; recording state is unknown."
        case .telemetryWriteSize: return "Camera readings need a larger Bluetooth write size."
        }
    }
}

struct NearbyCamera: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
}

/// All delegates and requests use the main queue. One request may be in flight.
/// Core Bluetooth's legacy delegate protocols don't declare that isolation;
/// the central's explicit .main queue supplies it for both delegate conformances.
@MainActor final class BluetoothCamera: NSObject, CameraLink, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    static let service = CBUUID(string: "0000BE80-0000-1000-8000-00805F9B34FB")
    static let writeID = CBUUID(string: "0000BE81-0000-1000-8000-00805F9B34FB")
    static let notifyID = CBUUID(string: "0000BE82-0000-1000-8000-00805F9B34FB")
    private(set) var isReady = false
    private(set) var connectionID: UUID?
    private(set) var nearby: [NearbyCamera] = []
    private(set) var connection = "Bluetooth starting"
    var changed: (() -> Void)?
    var ready: (() -> Void)?
    var lost: (() -> Void)?
    var statusChanged: (() -> Void)?
    var batteryChanged: ((Int?) -> Void)?
    var budgetWarning: ((Bool) -> Void)?
    var log: ((String) -> Void)?
    var permitConnection = true
    // Only foreground work or a running command may replace a stalled attempt.
    var permitRecovery = false
    var permitScan = true {
        didSet {
            if permitScan && !oldValue { automaticScanAttempted = false }
        }
    }
    var hasSavedCamera: Bool { savedCameraID != nil }
    private var savedCameraID: UUID? {
        UserDefaults.standard.string(forKey: "cameraIdentifier").flatMap(UUID.init(uuidString:))
    }
    private var automaticScanAttempted = false
    private var scanning = false
    private var central: CBCentralManager!
    private var discovered: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var writer: CBCharacteristic?
    private var notifier: CBCharacteristic?
    private var decoder = UCD2Decoder()
    private var messageID = UInt32.random(in: 1...0x1fffffff)
    private var sequence: UInt8 = 0
    private var pending: CheckedContinuation<[UInt8], Error>?
    private var pendingID: UInt32?
    private var pendingCommand: CameraCommand?
    private var pendingStarted: TimeInterval?
    private var timeout: Task<Void, Never>?
    private var scanTimeout: Task<Void, Never>?
    private var writeChunks: [Data] = []
    private var outstandingWrites: [UInt32] = []
    private var heartbeatCount = 0
    private var lastReceivedAt: TimeInterval?
    private var lastRequestAt: TimeInterval?
    private var recovery = ConnectionRecovery()
    private var cancellingConnection = false
    private let now: () -> TimeInterval

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func scan() {
        beginScan(automatic: false)
    }

    private func beginScan(automatic: Bool) {
        guard permitScan, permitConnection, peripheral == nil, !scanning,
              central.state == .poweredOn else { return }
        scanning = true
        automaticScanAttempted = true
        nearby = []; discovered = [:]
        central.scanForPeripherals(withServices: [Self.service])
        connection = "Scanning for X6 (10 seconds)"; changed?(); log?("scan_started")
        scanTimeout?.cancel()
        scanTimeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            guard let self else { return }
            self.stopScan()
            guard self.peripheral == nil, self.permitConnection, self.permitScan else { return }
            if automatic || self.hasSavedCamera,
               let id = CameraSelection.automaticID(saved: self.savedCameraID,
                    candidates: self.nearby.map { CameraCandidate(id: $0.id, name: $0.name) }) {
                self.select(id)
                return
            }
            self.connection = self.hasSavedCamera ? "Saved camera not found" :
                (self.nearby.isEmpty ? "No X6 found — reopen app to retry" : "Choose camera in Settings → Camera")
            self.changed?()
        }
    }

    func select(_ id: UUID) {
        guard permitConnection, peripheral == nil, let found = discovered[id] else { return }
        guard savedCameraID == nil || savedCameraID == id else { return }
        UserDefaults.standard.set(id.uuidString, forKey: "cameraIdentifier")
        connect(found)
    }

    func stopScan() {
        central.stopScan(); scanTimeout?.cancel(); scanTimeout = nil
        scanning = false
    }

    func requestReconnect() {
        guard permitConnection, central.state == .poweredOn, !isReady else { return }
        let now = self.now()
        if let peripheral {
            guard !cancellingConnection else { return }
            if peripheral.state == .disconnected {
                if recovery.canRetry(at: now) { connect(peripheral) }
            } else if peripheral.state != .disconnecting, permitRecovery, recovery.setupExpired(at: now) {
                recovery.failed(at: now)
                cancelConnection(peripheral, reason: "setup_timeout")
            }
            return
        }
        guard recovery.canRetry(at: now) else { return }
        guard let id = savedCameraID else {
            if !automaticScanAttempted { beginScan(automatic: true) }
            return
        }
        if let found = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(found)
        } else if !automaticScanAttempted {
            // A lost Core Bluetooth cache may require scanning, but only for
            // the saved identifier, never adopting another nearby camera.
            beginScan(automatic: true)
        }
    }

    private func connect(_ found: CBPeripheral) {
        stopScan()
        recovery.began(at: now())
        cancellingConnection = false
        peripheral = found; found.delegate = self
        connection = "Connecting…"; changed?(); log?("[connection] connecting")
        central.connect(found)
    }

    private func cancelConnection(_ peripheral: CBPeripheral, reason: String) {
        if self.peripheral === peripheral {
            guard !cancellingConnection else { return }
            cancellingConnection = true
        }
        log?("[connection] cancel_requested reason=\(reason) state=\(peripheral.state.rawValue)")
        central.cancelPeripheralConnection(peripheral)
    }

    func suspendConnection(reason: String) {
        stopScan()
        if let peripheral, peripheral.state != .disconnected {
            cancelConnection(peripheral, reason: reason)
            clearConnection(keepPeripheral: true)
        } else { clearConnection() }
        connection = "Paused in background"; changed?(); log?("connection_paused")
    }

    func forget() {
        UserDefaults.standard.removeObject(forKey: "cameraIdentifier")
        suspendConnection(reason: "forget_camera")
        automaticScanAttempted = true
        connection = "Scan to select a camera"; changed?()
    }

    func request(_ command: CameraCommand) async throws -> [UInt8] {
        guard pending == nil else { throw SessionError.busy }
        guard isReady, let peripheral, let writer else { throw LinkError.unavailable }
        try CommandDeadline.check()
        messageID = messageID == 0x3fffffff ? 1 : messageID + 1
        sequence &+= 1
        let packet = try UCD2.encode(command, id: messageID, sequence: sequence)
        let id = messageID
        let chunkSize = peripheral.maximumWriteValueLength(for: .withResponse)
        guard chunkSize > 0 else { throw LinkError.writeFailed }
        // Optional reads can be preempted by STOP. Do not leave a partial UCD2
        // packet in the camera's stream if cancellation happens between chunks.
        // Capture commands keep their established fragmented-write support.
        guard command != .telemetry || chunkSize >= packet.count else {
            log?("telemetry_write_size_unavailable maximum=\(chunkSize) required=\(packet.count)")
            throw LinkError.telemetryWriteSize
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation; pendingID = id
                pendingCommand = command; pendingStarted = ProcessInfo.processInfo.systemUptime
                lastRequestAt = pendingStarted
                writeChunks = stride(from: 0, to: packet.count, by: chunkSize).map {
                    Data(packet[$0..<min($0 + chunkSize, packet.count)])
                }
                log?("request code=\(command.rawValue) id=\(id)")
                let limit = CommandTimeouts.reply(for: command)
                timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000)) } catch { return }
                    self?.finish(.failure(LinkError.timeout), id: id)
                }
                outstandingWrites.append(id)
                peripheral.writeValue(writeChunks.removeFirst(), for: writer, type: .withResponse)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(LinkError.cancelled), id: id) }
        }
    }

    private func finish(_ result: Result<[UInt8], Error>, id: UInt32? = nil) {
        guard let continuation = pending, id == nil || id == pendingID else { return }
        let elapsed = pendingStarted.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        let outcome: String
        switch result {
        case .success: outcome = "reply_received"
        case .failure(let error): outcome = String(reflecting: error)
        }
        log?("request_finished code=\(pendingCommand?.rawValue ?? 0) id=\(pendingID ?? 0) elapsed=\(elapsed) ready=\(isReady) outcome=\(outcome)")
        timeout?.cancel(); timeout = nil; writeChunks = []
        pending = nil; pendingID = nil
        pendingCommand = nil; pendingStarted = nil
        continuation.resume(with: result)
    }

    private func clearConnection(keepPeripheral: Bool = false) {
        isReady = false; writer = nil; notifier = nil; decoder.reset()
        connectionID = nil
        outstandingWrites = []
        finish(.failure(LinkError.unavailable))
        // Await cancellation's disconnect callback before reconnecting the same
        // CBPeripheral, so a late callback cannot tear down its new session.
        if !keepPeripheral { peripheral = nil; cancellingConnection = false }
        lost?()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log?("bluetooth_state=\(central.state.rawValue)")
        if central.state == .poweredOn { connection = "Ready to connect"; requestReconnect() }
        else {
            stopScan(); automaticScanAttempted = false
            clearConnection(); connection = "Bluetooth unavailable (\(central.state.rawValue))"
        }
        changed?()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanning, permitScan else { return }
        if let saved = savedCameraID, saved != peripheral.identifier { return }
        discovered[peripheral.identifier] = peripheral
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Unknown camera"
        let camera = NearbyCamera(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        nearby.removeAll { $0.id == camera.id }; nearby.append(camera); changed?()
        if savedCameraID == peripheral.identifier { select(peripheral.identifier) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral === peripheral, permitConnection else {
            cancelConnection(peripheral, reason: "connection_not_permitted"); return
        }
        guard !cancellingConnection else { return }
        decoder.reset(); lastReceivedAt = nil; lastRequestAt = nil
        log?("[connection] connected; discovering services")
        connection = "Discovering camera services…"; changed?()
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        recovery.failed(at: now())
        clearConnection(); connection = "Connection failed; tap Reconnect"
        log?("[connection] connect_failed \(error?.localizedDescription ?? "unknown")"); changed?()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let receiveAge = lastReceivedAt.map { String(format: "%.2f", now - $0) } ?? "none"
        let requestAge = lastRequestAt.map { String(format: "%.2f", now - $0) } ?? "none"
        log?("[connection] disconnected error=\(error.map { String(reflecting: $0) } ?? "none") rx_age_s=\(receiveAge) request_age_s=\(requestAge) permitted=\(permitConnection)")
        clearConnection(); connection = "Disconnected"; changed?()
        // A single pending connect lets Core Bluetooth wait for the camera to return.
        // No recurring scan or background retry timer.
        requestReconnect()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral, !cancellingConnection else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            failSetup(error ?? LinkError.missingServices); return
        }
        peripheral.discoverCharacteristics([Self.writeID, Self.notifyID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral, !cancellingConnection else { return }
        guard error == nil,
              let writer = service.characteristics?.first(where: { $0.uuid == Self.writeID }),
              let notifier = service.characteristics?.first(where: { $0.uuid == Self.notifyID }),
              writer.properties.contains(.write), notifier.properties.contains(.notify) else {
            failSetup(error ?? LinkError.missingServices); return
        }
        self.writer = writer; self.notifier = notifier
        peripheral.setNotifyValue(true, for: notifier)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, !cancellingConnection, characteristic.uuid == Self.notifyID else { return }
        guard error == nil, characteristic.isNotifying else { failSetup(error ?? LinkError.missingServices); return }
        recovery.ready()
        if !isReady { connectionID = UUID() }
        isReady = true; connection = "Connected"; log?("[connection] notify_ready"); changed?(); ready?()
    }

    private func failSetup(_ error: Error) {
        log?("setup_error \(String(reflecting: error))")
        recovery.failed(at: now())
        if let peripheral, peripheral.state != .disconnected {
            cancelConnection(peripheral, reason: "setup_failed")
            clearConnection(keepPeripheral: true)
        } else { clearConnection() }
        connection = error.localizedDescription; changed?()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, characteristic.uuid == Self.writeID else { return }
        guard !outstandingWrites.isEmpty else { return }
        let writeID = outstandingWrites.removeFirst()
        guard writeID == pendingID else { return } // Ignore a late ATT callback after request timeout.
        if let error { log?("write_error \(error)"); finish(.failure(LinkError.writeFailed)); return }
        if pending != nil, !writeChunks.isEmpty {
            outstandingWrites.append(writeID)
            peripheral.writeValue(writeChunks.removeFirst(), for: characteristic, type: .withResponse)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, characteristic.uuid == Self.notifyID else { return }
        if let error {
            log?("notification_error \(String(reflecting: error))")
            if let bluetoothError = error as? CBError {
                // Near-limit is advance warning only: delivery continues, so an
                // in-flight STOP must not be failed or camera state discarded.
                if bluetoothError.code == .leGattNearBackgroundNotificationLimit { budgetWarning?(false); return }
                if bluetoothError.code == .leGattExceededBackgroundNotificationLimit { budgetWarning?(true) }
            }
            finish(.failure(error)); statusChanged?(); return
        }
        guard let value = characteristic.value else { return }
        lastReceivedAt = ProcessInfo.processInfo.systemUptime
        do {
            for message in try decoder.feed(Array(value)) {
                if message.type == 5 {
                    heartbeatCount += 1
                    if heartbeatCount == 1 || heartbeatCount % 60 == 0 { log?("heartbeat_count=\(heartbeatCount)") }
                    continue
                }
                if message.code == 8195 {
                    // Optional data must never fail an unrelated capture request.
                    do {
                        let percent = try CameraTelemetry.decodeBatteryNotification(message.body)
                        batteryChanged?(percent)
                        log?("battery_event percent=\(percent.map(String.init) ?? "unavailable") body=\(Array(message.body.prefix(64)).hex)")
                    } catch { log?("battery_event_invalid \(error)"); batteryChanged?(nil) }
                    continue
                }
                if message.code == 8208 { statusChanged?(); log?("camera_status_event"); continue }
                guard message.id == pendingID else {
                    if message.code == 200 {
                        log?("unmatched_reply id=\(message.id) pending_id=\(pendingID ?? 0)")
                    }
                    continue
                }
                log?("response code=\(message.code) id=\(message.id)")
                if pendingCommand == .telemetry {
                    log?("telemetry_reply bytes=\(message.body.count) body=\(Array(message.body.prefix(128)).hex)")
                }
                if message.code == 200 { finish(.success(message.body), id: message.id) }
                else { finish(.failure(ProtocolError.cameraRejected(message.code)), id: message.id) }
            }
        } catch { log?("decode_error \(error)"); finish(.failure(error)); statusChanged?() }
    }
}

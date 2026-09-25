import Foundation
import CoreBluetooth

@main struct RecoveryChecks {
    @MainActor static func main() async {
        // The harness is a separate executable with an isolated defaults suite
        // identity; preserve any saved value even though this is not the app.
        let saved = UserDefaults.standard.object(forKey: "cameraIdentifier")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "cameraIdentifier") }
            else { UserDefaults.standard.removeObject(forKey: "cameraIdentifier") }
        }
        let peripheral = CBPeripheral()
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "cameraIdentifier")
        var time = 0.0
        let link = BluetoothCamera(now: { time })
        let central = CBCentralManager.latest!
        central.retrieved = [peripheral]
        link.permitRecovery = true
        link.requestReconnect()
        precondition(central.connects == 1)

        // Native failure callback used to leave foreground recovery stalled.
        peripheral.state = .disconnected
        link.centralManager(central, didFailToConnect: peripheral, error: nil)
        link.requestReconnect()
        precondition(central.connects == 1, "Do not spin on failed connect")
        time = 1
        link.requestReconnect()
        precondition(central.connects == 2, "Foreground tick must retry failure")

        // Service setup that never completes must be replaced while active.
        peripheral.state = .connected
        link.centralManager(central, didConnect: peripheral)
        time = 14
        link.requestReconnect()
        precondition(central.cancels == 1, "Stalled service discovery must be cancelled")
        let service = CBService(BluetoothCamera.service)
        service.characteristics = [CBCharacteristic(BluetoothCamera.writeID), CBCharacteristic(BluetoothCamera.notifyID)]
        peripheral.services = [service]
        link.peripheral(peripheral, didDiscoverServices: nil)
        link.peripheral(peripheral, didUpdateNotificationStateFor: service.characteristics![1], error: nil)
        precondition(!link.isReady, "Late setup callbacks cannot revive cancelled link")
        time = 20
        link.requestReconnect()
        precondition(central.connects == 2, "Wait for cancellation callback")
        peripheral.state = .disconnected
        link.centralManager(central, didDisconnectPeripheral: peripheral, error: nil)
        precondition(central.connects == 3)

        // Background runtime gaps must not cause an autonomous cancellation loop.
        link.permitRecovery = false
        time = 2000
        link.requestReconnect()
        precondition(central.cancels == 1)
        link.permitRecovery = true
        link.requestReconnect()
        precondition(central.cancels == 2)
        time = 2010
        peripheral.state = .disconnected
        link.centralManager(central, didDisconnectPeripheral: peripheral, error: nil)
        precondition(central.connects == 4)

        // Resume before a policy cancellation callback must not reuse its link.
        link.permitConnection = false
        link.suspendConnection(reason: "test_policy")
        link.permitConnection = true
        link.requestReconnect()
        precondition(central.connects == 4)
        peripheral.state = .disconnected
        link.centralManager(central, didDisconnectPeripheral: peripheral, error: nil)
        precondition(central.connects == 5)
        precondition(peripheral.writes.isEmpty, "Recovery cannot send capture commands")

        // A near-limit budget warning is advance notice only: it must not fail
        // the in-flight request (possibly STOP). Exceeding the limit still does.
        peripheral.state = .connected
        link.centralManager(central, didConnect: peripheral)
        link.peripheral(peripheral, didDiscoverServices: nil)
        link.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: nil)
        link.peripheral(peripheral, didUpdateNotificationStateFor: service.characteristics![1], error: nil)
        precondition(link.isReady, "Setup must complete for the budget check")
        var warnings: [Bool] = []
        var invalidations = 0
        link.budgetWarning = { warnings.append($0) }
        link.statusChanged = { invalidations += 1 }
        let request = Task { try await link.request(.status) }
        for _ in 0..<100 where peripheral.writes.isEmpty { await Task.yield() }
        precondition(peripheral.writes.count == 1, "Status request must be written")
        let notifier = service.characteristics![1]
        link.peripheral(peripheral, didUpdateValueFor: notifier, error: CBError(code: .leGattNearBackgroundNotificationLimit))
        precondition(warnings == [false] && invalidations == 0, "Near-limit warning must not invalidate state")
        link.peripheral(peripheral, didUpdateValueFor: notifier, error: CBError(code: .leGattExceededBackgroundNotificationLimit))
        switch await request.result {
        case .success: preconditionFailure("Exceeded limit must fail the pending request")
        case .failure(let error):
            precondition((error as? CBError)?.code == .leGattExceededBackgroundNotificationLimit,
                         "Pending request must fail with the exceeded-limit error, not the warning")
        }
        precondition(warnings == [false, true] && invalidations == 1)
        print("PASS: actual BluetoothCamera callback/retry/cancellation paths using simulated CoreBluetooth; no hardware claim")
    }
}

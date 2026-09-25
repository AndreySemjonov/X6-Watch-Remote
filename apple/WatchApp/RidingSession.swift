import Foundation
import CoreLocation

/// Location-backed runtime for a ride. Fixes are counted for diagnostics only;
/// coordinates are never stored, logged or sent anywhere.
///
/// Starting background location while active keeps the app running afterwards
/// and shows the location glyph on the watch face (tap returns to X6 Remote).
/// Unlike a second workout, it does not end SURFR's workout session.
/// It must be started while the app is active; watchOS refuses a background start.
@MainActor final class RidingSession: NSObject, @preconcurrency CLLocationManagerDelegate {
    enum State: Equatable { case off, waitingForPermission, running, denied }
    private(set) var state: State = .off
    var changed: (() -> Void)?
    var log: ((String) -> Void)?
    var isRunning: Bool { state == .running }
    private let manager = CLLocationManager()
    private var activity: CLBackgroundActivitySession?
    private var wanted = false
    private var fixes = 0

    override init() {
        super.init()
        manager.delegate = self
        // SURFR normally keeps GPS on already; a coarse request avoids asking
        // for more than runtime needs. Physical tests decide if this suffices.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 100
    }

    func start() {
        wanted = true
        switch manager.authorizationStatus {
        case .notDetermined:
            set(.waitingForPermission)
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted: set(.denied)
        default: begin()
        }
    }

    func stop() {
        wanted = false
        guard state != .off else { return }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        activity?.invalidate(); activity = nil
        set(.off)
    }

    private func begin() {
        guard wanted, state != .running else { return }
        fixes = 0
        manager.allowsBackgroundLocationUpdates = true
        activity = CLBackgroundActivitySession()
        manager.startUpdatingLocation()
        set(.running)
    }

    private func set(_ value: State) {
        guard value != state else { return }
        state = value
        log?("[connection] riding_session=\(value)")
        changed?()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        log?("riding_location_authorization=\(status.rawValue)")
        guard wanted else { return }
        switch status {
        case .notDetermined: break
        case .denied, .restricted:
            stop(); wanted = true; set(.denied)
        default: begin()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        fixes += locations.count
        if fixes == 1 || fixes % 60 == 0 { log?("riding_location_fixes=\(fixes)") }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // locationUnknown is transient; Core Location keeps trying.
        if (error as? CLError)?.code == .locationUnknown { return }
        log?("riding_location_error \(String(reflecting: error))")
        if (error as? CLError)?.code == .denied { stop(); wanted = true; set(.denied) }
    }
}

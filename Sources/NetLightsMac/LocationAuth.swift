import Foundation
import CoreLocation

/// Requests Location authorization for the *sole* purpose of reading the current
/// Wi-Fi network name (SSID). On macOS 14+, `CWInterface.ssid()` returns nil
/// unless the app has Location access — Apple gates SSID behind location because
/// a known SSID can reveal physical location. NetLights uses it for nothing else
/// (no tracking, no coordinates are ever read or stored).
///
/// Note: this only prompts from the packaged NetLights.app (which carries the
/// usage-description string). Run via `swift run`, there's no prompt and SSID
/// stays nil — the egress simply shows "Wi-Fi" without the network name.
final class LocationAuth: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    /// Called whenever authorization changes, so the UI can re-read the SSID.
    var onAuthorizationChange: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    func request() {
        manager.requestWhenInUseAuthorization()
    }

    /// Whether Location access is currently granted (so the SSID can be read).
    var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return true
        default:                                      return false
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?()
    }
}

import Foundation
import IOBluetooth

/// Reads the list of *connected* Bluetooth devices via the classic IOBluetooth
/// API (paired devices + connection state). Read-only — it never scans, pairs, or
/// connects; it just reflects what macOS already knows.
///
/// TCC gate: touching ANY IOBluetooth API from a process whose Info.plist lacks
/// `NSBluetoothAlwaysUsageDescription` triggers an immediate privacy CRASH
/// (`__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__`) — verified empirically. So under
/// `swift run` (SwiftPM's bundle has no such key) we must not call the framework
/// at all; the packaged app declares the key and the first read prompts the user.
/// If the user declines, the API simply returns nothing — we degrade gracefully.
enum BluetoothProbe {

    struct RawBT {
        let address: String   // "14-c2-13-ee-38-3a"
        let name: String
        let major: Int        // Class-of-Device major
        let minor: Int        // Class-of-Device minor
    }

    /// True only when the bundle declares the Bluetooth usage string. Anything that
    /// reads Bluetooth must check this first to avoid the TCC crash described above.
    static var available: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil
    }

    /// Currently-connected paired devices. Empty when Bluetooth isn't available to
    /// us (dev build / permission declined). Call on the main actor — IOBluetooth's
    /// classic API expects the main run loop.
    @MainActor static func connectedDevices() -> [RawBT] {
        guard available else { return [] }
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return [] }
        return paired.compactMap { d in
            guard d.isConnected() else { return nil }
            return RawBT(address: d.addressString ?? "",
                         name: (d.name?.isEmpty == false ? d.name! : "Bluetooth device"),
                         major: Int(d.deviceClassMajor),
                         minor: Int(d.deviceClassMinor))
        }
    }
}

/// Normalize a Bluetooth address for matching across sources (IOBluetooth uses
/// "14-c2-13-ee-38-3a"; the HID registry uses the same but casing/separators vary).
func normalizeBTAddress(_ s: String) -> String {
    s.lowercased().filter(\.isHexDigit)
}

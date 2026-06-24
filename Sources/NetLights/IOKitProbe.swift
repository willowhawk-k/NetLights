import Foundation
import IOKit
import CoreGraphics
import AppKit

/// In-process replacements for the `ioreg` / `system_profiler` subprocesses.
///
/// The App Sandbox (required by the Mac App Store) forbids launching external
/// executables, so NetLights cannot shell out to `/usr/sbin/ioreg` or
/// `system_profiler` in a sandboxed build. Everything those tools surfaced is
/// just a serialization of the I/O Registry (and CoreGraphics display state),
/// which is readable in-process via IOKit + CoreGraphics — sandbox-permitted
/// (`iokit-get-properties` is allowed) and entitlement-free for property reads.
/// One implementation therefore works in BOTH the Developer-ID and App Store builds.
enum IOKitProbe {

    // MARK: - I/O Registry primitives

    /// Every property of a registry entry (the same dictionary `ioreg -a` serializes).
    static func properties(of entry: io_registry_entry_t) -> [String: Any] {
        var raw: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = raw?.takeRetainedValue() as? [String: Any] else { return [:] }
        return dict
    }

    /// Class name of a registry entry (not a CFProperty; fetched separately, like ioreg).
    static func className(of entry: io_registry_entry_t) -> String? {
        guard let cf = IOObjectCopyClass(entry)?.takeRetainedValue() else { return nil }
        return cf as String
    }

    /// Builds a nested `[String: Any]` tree over the IOService plane rooted at
    /// `entry`, mirroring `ioreg -a -l`: each node is its property dict, with the
    /// class under "IOObjectClass" and children under "IORegistryEntryChildren".
    /// This lets the existing registry-walking parsers run unchanged.
    static func tree(of entry: io_registry_entry_t) -> [String: Any] {
        var node = properties(of: entry)
        if let cls = className(of: entry) { node["IOObjectClass"] = cls }

        var iter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, "IOService", &iter) == KERN_SUCCESS else {
            return node
        }
        defer { IOObjectRelease(iter) }
        var children: [[String: Any]] = []
        var child = IOIteratorNext(iter)
        while child != 0 {
            children.append(tree(of: child))
            IOObjectRelease(child)
            child = IOIteratorNext(iter)
        }
        if !children.isEmpty { node["IORegistryEntryChildren"] = children }
        return node
    }

    /// The whole IOService-plane registry as a nested dict (equivalent to `ioreg -a -l`).
    static func serviceTree() -> [String: Any] {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return [:] }
        defer { IOObjectRelease(root) }
        return tree(of: root)
    }

    /// Property dict of each IOService matching `className` (replaces `ioreg -c`).
    static func forEach(matching className: String, _ body: ([String: Any]) -> Void) {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching(className), &iter) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iter) }
        var entry = IOIteratorNext(iter)
        while entry != 0 {
            body(properties(of: entry))
            IOObjectRelease(entry)
            entry = IOIteratorNext(iter)
        }
    }

    // MARK: - USB-C Power Delivery (AppleHPM) — replaces `ioreg -c AppleHPMInterfaceType10`

    /// Per USB-C port: whether anything is attached, and whether it's power-only.
    static func usbCPower() -> (connected: [Int: Bool], power: [Int: Bool]) {
        var connected: [Int: Bool] = [:]
        var power: [Int: Bool] = [:]
        forEach(matching: "AppleHPMInterfaceType10") { p in
            guard let port = (p["PortNumber"] as? NSNumber)?.intValue else { return }
            let active  = (p["ConnectionActive"] as? NSNumber)?.boolValue ?? false
            let connStr = p["IOAccessoryUSBConnectString"] as? String ?? ""
            connected[port] = active
            power[port] = active && connStr == "None"   // active, no data device ⇒ charger
        }
        return (connected, power)
    }

    // MARK: - System power (AppleSmartBattery) — SYSTEM-level only

    /// Whether the Mac is on external (AC/USB-C) power, whether the battery is
    /// charging, and the adapter wattage. This is the ONLY power-delivery fact
    /// macOS exposes to an app: it is SYSTEM-wide, NOT per-port — there is no
    /// public signal for which USB-C port sources/sinks power (verified against a
    /// known sink+source setup: the ports are byte-for-byte identical power-wise).
    /// Returns nil on Macs without a battery (desktops).
    static func systemPower() -> (onAC: Bool, charging: Bool, watts: Int?)? {
        var result: (onAC: Bool, charging: Bool, watts: Int?)?
        forEach(matching: "AppleSmartBattery") { p in
            let onAC = (p["ExternalConnected"] as? NSNumber)?.boolValue ?? false
            let charging = (p["IsCharging"] as? NSNumber)?.boolValue ?? false
            let watts = (p["AdapterDetails"] as? [String: Any])?["Watts"] as? NSNumber
            result = (onAC, charging, watts?.intValue)
        }
        return result
    }

    // MARK: - Displays (CoreGraphics) — replaces `system_profiler SPDisplaysDataType`

    struct RawDisplay {
        let id: UInt32          // CGDirectDisplayID (stable for the session)
        let vendor: UInt32      // EDID manufacturer id
        let model: UInt32
        let serial: UInt32
        let width: Int
        let height: Int
        let refreshHz: Double
    }

    /// External displays via CoreGraphics (thread-safe; the built-in panel is
    /// excluded). Sandbox-safe and entitlement-free.
    static func externalDisplays() -> [RawDisplay] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.filter { CGDisplayIsBuiltin($0) == 0 }.map { id in
            let mode = CGDisplayCopyDisplayMode(id)
            return RawDisplay(id: id,
                              vendor: CGDisplayVendorNumber(id),
                              model: CGDisplayModelNumber(id),
                              serial: CGDisplaySerialNumber(id),
                              width: mode?.pixelWidth ?? 0,
                              height: mode?.pixelHeight ?? 0,
                              refreshHz: mode?.refreshRate ?? 0)
        }
    }

    /// CGDirectDisplayID → human-readable name (NSScreen.localizedName). Must run on
    /// the main actor (AppKit), so callers fetch it on main and pass it into the
    /// off-main port query.
    @MainActor static func displayNames() -> [UInt32: String] {
        var map: [UInt32: String] = [:]
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                map[num.uint32Value] = screen.localizedName
            }
        }
        return map
    }
}

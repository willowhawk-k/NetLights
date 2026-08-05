import Foundation

// System power from /sys/class/power_supply. Pure, in Core, for the same two reasons as the
// USB and EDID parsers: it must be testable off-Linux, and `SystemPower`'s stored properties
// are internal so the Linux module cannot construct one.

/// One /sys/class/power_supply/<name> entry as read from disk.
public struct PowerSupplyReading: Equatable, Sendable {
    public let name: String
    public let attributes: [String: String]
    public init(name: String, attributes: [String: String]) {
        self.name = name; self.attributes = attributes
    }
    func value(_ key: String) -> String? {
        guard let v = attributes[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !v.isEmpty else { return nil }
        return v
    }
    func int(_ key: String) -> Int? { value(key).flatMap { Int($0) } }
}

/// Assemble SystemPower from the power_supply entries.
///
/// Returns nil when there is no battery and no mains supply — a desktop or a VM, where the
/// whole battery entity should be absent rather than reported as "unknown".
public func buildSystemPower(_ readings: [PowerSupplyReading]) -> SystemPower? {
    var sawBattery = false, sawMains = false
    var onAC = false, charging = false, full = false
    var level: Int?
    var watts: Int?
    var adapterName: String?

    for r in readings {
        // `scope` == "Device" marks a PERIPHERAL battery (a wireless mouse, a USB-PD
        // accessory). Those are not the machine's own power and must not drive the system
        // battery entity — they belong to their device chip.
        let scope = r.value("scope")
        guard scope == nil || scope == "System" else { continue }

        switch r.value("type") {
        case "Battery":
            sawBattery = true
            if let c = r.int("capacity") { level = c }
            switch r.value("status") {
            case "Charging": charging = true; onAC = true
            case "Full": full = true; onAC = true
            case "Not charging": onAC = true    // plugged in, holding at a charge limit
            default: break
            }
        case "Mains", "USB", "USB_PD", "USB_PD_DRP", "USB_C":
            sawMains = true
            if r.int("online") == 1 { onAC = true }
            if adapterName == nil {
                // model_name is the useful one ("140W USB-C Power Adapter"); manufacturer
                // alone ("Apple Inc.") is a weaker fallback.
                adapterName = r.value("model_name") ?? r.value("manufacturer")
            }
            if watts == nil { watts = adapterWatts(r) }
        default:
            continue
        }
    }
    guard sawBattery || sawMains else { return nil }
    return SystemPower(onAC: onAC, charging: charging, fullyCharged: full,
                       level: level, watts: watts, adapterName: adapterName)
}

/// The adapter's RATED wattage, matching what macOS puts in `watts`.
///
/// Deliberately not `power_now`: that is the instantaneous draw, so a 140 W adapter idling
/// would report "12W" and the status bar would look like a failing charger. Only a genuine
/// rating counts — the USB-PD negotiated limit, or voltage_max × current_max.
private func adapterWatts(_ r: PowerSupplyReading) -> Int? {
    if let uW = r.int("input_power_limit"), uW > 0 {          // microwatts (USB-PD)
        return Int((Double(uW) / 1_000_000).rounded())
    }
    if let uV = r.int("voltage_max"), let uA = r.int("current_max"), uV > 0, uA > 0 {
        // microvolts × microamps → watts
        return Int((Double(uV) / 1_000_000 * Double(uA) / 1_000_000).rounded())
    }
    return nil
}

/// Peripheral batteries (`scope` == "Device") → a battery percentage per device, keyed by the
/// supply's own name. A wireless mouse's charge belongs on its device chip, not on the
/// machine's battery entity.
public func peripheralBatteryLevels(_ readings: [PowerSupplyReading]) -> [String: Int] {
    var out: [String: Int] = [:]
    for r in readings where r.value("scope") == "Device" {
        if let c = r.int("capacity") { out[r.name] = c }
    }
    return out
}

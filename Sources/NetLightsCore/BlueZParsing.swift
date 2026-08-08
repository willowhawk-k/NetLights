import Foundation

// BlueZ's ObjectManager tree → Bluetooth device chips (receptacle -4).
//
// Pure, and in Core because AttachedDevice has no public init and the three classifiers are
// internal to this module. The Linux side supplies the decoded D-Bus reply; everything from
// here on is platform-neutral and testable from macOS.
//
// The output must match what NetworkMonitor.buildBluetooth produces on macOS, field for
// field, so the same device renders identically on both platforms. In particular the fields
// macOS leaves nil are left nil here on purpose:
//   * `detail` — `speedLabel` returns `detail` ahead of everything else, so a value here
//     would print where macOS prints "—".
//   * `vendorID`/`productID` — they would displace the address in `idLabel`. This is why
//     Device1's `Modalias` (which does carry a vendor/product pair) is deliberately not
//     decoded.

/// BlueZ's wire form ("14:C2:13:EE:38:3A") → the IOBluetooth display form macOS emits
/// ("14-c2-13-ee-38-3a"). nil unless it is exactly six colon-separated hex octets.
public func btAddressDisplay(_ bluezAddress: String) -> String? {
    let parts = bluezAddress.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 6,
          parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
    return parts.joined(separator: "-").lowercased()
}

/// True for BlueZ's synthetic Alias fallback ("14-C2-13-EE-38-3A") — an address wearing a
/// name's clothes, which must never be shown as a device name.
public func btAliasIsSyntheticAddress(_ alias: String) -> Bool {
    let parts = alias.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 6 else { return false }
    return parts.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isHexDigit) }
}

private let deviceInterface = "org.bluez.Device1"
private let batteryInterface = "org.bluez.Battery1"

/// GAP Appearance → device kind. BLE-only peripherals carry no Class-of-Device at all, so
/// this (and `Icon`) is the only classification signal available for them — the macOS
/// classifier is Class-of-Device based and would return generic for every BLE device.
/// The value's top 6 bits are the category; the low 6 bits are a sub-category.
private func kindFromAppearance(_ appearance: Int) -> USBDeviceKind? {
    // Category is the top 10 bits, sub-category the low 6. Getting the shift wrong is
    // invisible at runtime — every BLE input device just becomes a generic cube — so the
    // category constants below are the values verified against real Appearance codes
    // (0x03C2 → category 0x00F, sub 0x02 = Mouse), not guessed.
    switch appearance >> 6 {
    case 0x000: return nil            // Unknown / not set
    case 0x002: return .computer
    case 0x00F:                       // Human Interface Device
        switch appearance & 0x3F {
        case 0x01: return .keyboard
        case 0x02: return .pointing
        case 0x03: return .gamecontroller   // Joystick
        case 0x04: return .gamecontroller   // Gamepad
        case 0x05: return .pointing         // Digitizer tablet
        case 0x09: return .pointing         // Touchpad
        default:   return nil
        }
    case 0x021: return .audio         // Audio Sink — speaker, headphones
    case 0x025: return .audio         // Wearable audio
    case 0x02A: return .gamecontroller
    default:    return nil
    }
}

/// BlueZ's derived freedesktop icon name → device kind. A useful cross-check: BlueZ computes
/// it from Class OR Appearance, so it sometimes resolves a device where both of those are
/// individually unhelpful.
private func kindFromIcon(_ icon: String) -> USBDeviceKind? {
    switch icon {
    case "audio-headset", "audio-headphones", "audio-speakers", "audio-card": return .audio
    case "input-keyboard":            return .keyboard
    case "input-mouse", "input-tablet": return .pointing
    case "input-gaming":              return .gamecontroller
    case "camera-photo", "camera-video": return .camera
    case "video-display":             return .display
    case "computer":                  return .computer
    case "printer":                   return .generic
    case "phone":                     return .generic
    default:                          return nil
    }
}

/// Build the Bluetooth device chips from a decoded `GetManagedObjects` reply.
///
/// `managedObjects` is the `a{oa{sa{sv}}}` value: object path → interface → property → variant.
public func buildBluetoothDevices(managedObjects: DBusValue) -> [AttachedDevice] {
    guard let objects = managedObjects.asArray else { return [] }
    var out: [AttachedDevice] = []

    for entry in objects {
        guard case .dictEntry(_, let interfacesValue) = entry,
              let interfaces = interfacesValue.asStringMap else { continue }
        // Selection is by INTERFACE, never by path shape: a single connected LE peripheral
        // contributes 50-150 GATT child objects that all live under the device's own path,
        // so any prefix test on the path admits every one of them.
        guard let props = interfaces[deviceInterface]?.asStringMap else { continue }

        // Connected only, matching macOS (which filters IOBluetoothDevice.pairedDevices by
        // isConnected). A paired-but-absent device is not attached hardware.
        guard props["Connected"]?.asBool == true else { continue }
        guard let address = props["Address"]?.asString, !address.isEmpty else { continue }

        // macOS emits the IOBluetooth display form: lowercase, hyphen-separated. Matching it
        // is NOT cosmetic — PrivacyMask.isAddressChar accepts hex, "." and ":" but not "-",
        // so the hyphen form passes through privacy mode untouched exactly as macOS's does,
        // while a colon form would render as "14:C2:13:xx:xx:xx" on Linux and in full on
        // macOS. Same device, two different strings.
        guard let display = btAddressDisplay(address) else { continue }

        // Alias first: it is what every Linux UI shows and already falls back to Name. But
        // BlueZ synthesises an Alias from the address when nothing else is known, and that
        // must not become a device name — it would show a half-redacted address in the graph
        // and feed garbage to the name-keyword classifier.
        let alias = props["Alias"]?.asString.flatMap { btAliasIsSyntheticAddress($0) ? nil : $0 }
        let name = alias
            ?? props["Name"]?.asString.flatMap { $0.isEmpty ? nil : $0 }
            ?? "Bluetooth device"

        let kind = classifyBluetoothDevice(name: name,
                                           classOfDevice: props["Class"]?.asInt,
                                           appearance: props["Appearance"]?.asInt,
                                           icon: props["Icon"]?.asString)

        // Battery is a sibling INTERFACE on the same object, so it needs no second call and
        // no address join — strictly more reliable than the macOS path, which has to match
        // an IORegistry entry against the Bluetooth address.
        let battery = interfaces[batteryInterface]?.asStringMap?["Percentage"]?.asInt

        out.append(AttachedDevice(
            id: "bt-\(display)",
            name: name,
            receptacle: -4,
            kind: kind,
            serial: display,
            connection: "Bluetooth",
            batteryPercent: battery.map { min(max($0, 0), 100) }))
    }
    // A peer linked to two adapters (built-in plus a dongle) appears once per adapter with
    // the SAME id. `computeDevicePositions` writes result[d.id], so the duplicate silently
    // overwrites the first position and one chip is left with a slot but no node. Prefer the
    // entry that carries a battery, then the one with a real name.
    var byID: [String: AttachedDevice] = [:]
    for d in out {
        guard let existing = byID[d.id] else { byID[d.id] = d; continue }
        let better = (d.batteryPercent != nil && existing.batteryPercent == nil)
            || (existing.name == "Bluetooth device" && d.name != "Bluetooth device")
        if better { byID[d.id] = d }
    }
    return byID.values.sorted { $0.id < $1.id }
}

/// The classification cascade, mirroring `NetworkMonitor.buildBluetooth` and extending it
/// for BLE devices, which carry no Class-of-Device.
public func classifyBluetoothDevice(name: String, classOfDevice: Int?,
                             appearance: Int?, icon: String?) -> USBDeviceKind {
    // 24-bit Class of Device: major device class is bits 8-12, minor is bits 2-7. Those are
    // exactly IOBluetooth's deviceClassMajor/deviceClassMinor, so the shared classifier is
    // reused with no change.
    if let cod = classOfDevice {
        let major = (cod >> 8) & 0x1F
        let minor = (cod >> 2) & 0x3F
        // The audio/imaging exception from macOS: when the hardware class is authoritative,
        // skip the name entirely, so "Marshall Monitor II" headphones don't become a display.
        let codConfirmed = major == 0x04 || major == 0x06
        let byName: USBDeviceKind = codConfirmed ? .generic
            : USBDeviceKind.classify(name: name, classCode: -1)
        if byName != .generic { return byName }
        return USBDeviceKind.classifyBluetooth(major: major, minor: minor, name: name)
    }

    // No Class → a BLE-only peripheral. Name first (it is the most reliable signal we have),
    // then the GAP appearance, then BlueZ's own derived icon.
    let byName = USBDeviceKind.classify(name: name, classCode: -1)
    if byName != .generic { return byName }
    if let a = appearance, let k = kindFromAppearance(a) { return k }
    if let i = icon, let k = kindFromIcon(i) { return k }
    return .generic
}

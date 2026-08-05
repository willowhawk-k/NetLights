import Foundation

// The USB device tree, parsed from /sys/bus/usb/devices.
//
// Pure and in Core for two reasons. The first is the established one (DNSParsing,
// EDIDParsing): the implementer has no shell on the Linux VM, so captured sysfs content fed
// to these functions from macOS is the only available test signal. The second is structural
// — `AttachedDevice` and `HardwarePort` have no public initializer and
// `USBDeviceKind.classifyUSB` is internal to this module, so the Linux target *cannot*
// construct the models even if it wanted to. It passes strings in; Core returns finished
// values out. Do not "fix" that by making the memberwise inits public.

// MARK: - Input

/// One /sys/bus/usb/devices entry, with its attribute files read RAW.
///
/// Untrimmed on purpose: the kernel formats `version` as "%2x.%02x", so its leading space is
/// part of the contract and has to survive into the parser that strips it.
public struct USBSysfsNode: Equatable, Sendable {
    public let name: String
    public let attributes: [String: String]
    public init(name: String, attributes: [String: String]) {
        self.name = name; self.attributes = attributes
    }
}

public enum USBSysfsEntry: Equatable, Sendable {
    case rootHub(bus: Int)                                     // "usb1"
    case device(bus: Int, portPath: [Int])                     // "1-1.4"
    case interface(device: String, config: Int, number: Int)   // "1-1:1.0"
    case unknown
}

// MARK: - The directory-name grammar

/// Classify a /sys/bus/usb/devices entry by its name alone.
///
/// The critical case is `.interface`: every USB device also exposes one directory per
/// interface descriptor ("1-1:1.0"), and treating those as devices is the single easiest way
/// to fill the graph with phantom chips.
public func classifyUSBSysfsName(_ name: String) -> USBSysfsEntry {
    if let colon = name.firstIndex(of: ":") {
        let head = String(name[name.startIndex..<colon])
        let tail = name[name.index(after: colon)...]
        let parts = tail.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let cfg = Int(parts[0]), let num = Int(parts[1]),
              case .device = classifyUSBSysfsName(head) else { return .unknown }
        return .interface(device: head, config: cfg, number: num)
    }
    if name.hasPrefix("usb") {
        let rest = name.dropFirst(3)
        guard !rest.isEmpty, let bus = Int(rest) else { return .unknown }
        return .rootHub(bus: bus)
    }
    guard let dash = name.firstIndex(of: "-") else { return .unknown }
    guard let bus = Int(name[name.startIndex..<dash]) else { return .unknown }
    let path = name[name.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false)
    guard !path.isEmpty else { return .unknown }
    var ports: [Int] = []
    for p in path { guard let n = Int(p) else { return .unknown }; ports.append(n) }
    return .device(bus: bus, portPath: ports)
}

/// The parent directory name, derived from the name alone — sysfs encodes the hierarchy in
/// it. "1-1.4" → "1-1" → "usb1". Root hubs have no parent.
public func usbParentName(_ name: String) -> String? {
    guard case .device(let bus, let path) = classifyUSBSysfsName(name) else { return nil }
    if path.count > 1 {
        return "\(bus)-" + path.dropLast().map(String.init).joined(separator: ".")
    }
    return "usb\(bus)"
}

// MARK: - Scalar attribute parsers

public func usbTrimmed(_ raw: String?) -> String? {
    guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
    return t
}

/// Radix 16 is mandatory: every id and class in sysfs is lowercase hex, so a decimal parse
/// silently returns 9 for "09" and nil for "0e" — which is how class 0x0E (video) would go
/// missing and every webcam would classify as generic.
public func usbHex(_ raw: String?) -> Int? {
    usbTrimmed(raw).flatMap { Int($0, radix: 16) }
}

public func usbInt(_ raw: String?) -> Int? { usbTrimmed(raw).flatMap { Int($0) } }

/// The `version` attribute (" 2.10\n") → the model's usbVersion label ("USB 2.1").
/// The minor is the FIRST of the two hex digits — the same `(bcd >> 4) & 0xF` the macOS
/// probe computes, so both platforms label the same hub identically.
public func usbVersionLabel(_ raw: String?) -> String? {
    guard let t = usbTrimmed(raw) else { return nil }
    let parts = t.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, parts[1].count == 2,
          parts[0].allSatisfy(\.isHexDigit), parts[1].allSatisfy(\.isHexDigit),
          let minor = parts[1].first else { return nil }
    return "USB \(parts[0]).\(minor)"
}

/// The `speed` attribute, in Mbit/s as a decimal string, → bits/sec. Parsed as a Double
/// because low-speed devices report the fractional "1.5".
public func usbSpeedBps(_ raw: String?) -> UInt64? {
    guard let t = usbTrimmed(raw), t != "unknown", let mbit = Double(t), mbit > 0 else { return nil }
    return UInt64((mbit * 1_000_000).rounded())
}

/// /sys/block/<dev>/size is in fixed 512-byte sectors regardless of the device's logical
/// block size — do not multiply by queue/logical_block_size.
public func blockCapacityBytes(_ rawSize: String?) -> UInt64? {
    guard let t = usbTrimmed(rawSize), let sectors = UInt64(t), sectors > 0 else { return nil }
    return sectors &* 512
}

/// Walk a resolved sysfs path back to the USB device that owns it, so
/// /sys/class/net/<if>/device and /sys/block/<dev> can be tied to their device chip.
/// Returns nil for a non-USB device, which is the common case.
public func usbDeviceName(fromSysfsPath path: String) -> String? {
    for comp in path.split(separator: "/").reversed() {
        switch classifyUSBSysfsName(String(comp)) {
        case .interface(let owner, _, _): return owner
        case .device: return String(comp)
        default: continue
        }
    }
    return nil
}

/// /proc/bus/input/devices → USB device name → HID Generic-Desktop usage ids.
///
/// The usage numbers are chosen so the EXISTING `USBDeviceKind.classifyHIDUsages` resolves
/// them unchanged — 2 (Mouse) beats 6 (Keyboard) for a composite gaming mouse, and 4/5
/// (Joystick/Gamepad) give a game controller.
public func parseProcBusInputDevices(_ text: String) -> [String: Set<Int>] {
    var out: [String: Set<Int>] = [:]
    var sysfs: String?
    var usages: Set<Int> = []

    func flush() {
        if let s = sysfs, let dev = usbDeviceName(fromSysfsPath: s), !usages.isEmpty {
            out[dev, default: []].formUnion(usages)
        }
        sysfs = nil; usages = []
    }

    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { flush(); continue }
        if line.hasPrefix("I:") { flush() }           // a new block, even without a blank line
        if line.hasPrefix("S: Sysfs=") {
            sysfs = String(line.dropFirst("S: Sysfs=".count))
        } else if line.hasPrefix("H: Handlers=") {
            for token in line.dropFirst("H: Handlers=".count).split(separator: " ") {
                if token == "kbd" { usages.insert(6) }
                else if token.hasPrefix("mouse") { usages.insert(2) }
                else if token.hasPrefix("js") { usages.insert(4) }
            }
        }
    }
    flush()
    return out
}

/// The host-controller short name from a root hub's `product` string.
///
/// Root hubs are named after the controller that owns them — "xHCI Host Controller",
/// "EHCI Host Controller", "OHCI PCI host controller" — which is the most direct answer
/// available to "what kind of port is this really?". Worth surfacing: on a VM every device
/// hangs off an emulated controller on the virtual PCI bus, and the answer should say so
/// rather than leave the user guessing at the bus number.
public func usbControllerShortName(_ product: String?) -> String? {
    guard let p = usbTrimmed(product) else { return nil }
    for token in p.split(separator: " ") {
        // Match case-insensitively but return the token VERBATIM: the kernel writes "xHCI"
        // with a lowercase x, and uppercasing it to "XHCI" just looks wrong.
        guard token.uppercased().hasSuffix("HCI"), token.count <= 5 else { continue }
        return String(token)
    }
    return nil
}

// MARK: - Building the model

/// Not Sendable: AttachedDevice/HardwarePort aren't, and marking this Sendable is an error
/// in Swift 6 mode. It's a value returned from one collect call, never shared across tasks.
public struct USBTopology {
    public var devices: [AttachedDevice]
    public var ports: [HardwarePort]
    public init(devices: [AttachedDevice], ports: [HardwarePort]) {
        self.devices = devices; self.ports = ports
    }
}

/// Build the AttachedDevice forest plus one HardwarePort per non-empty USB bus.
///
/// The ports are not optional decoration: `GraphLayoutEngine.computeDevicePositions` skips
/// any device whose receptacle has no port position, so devices without a matching port
/// would be silently dropped from the graph.
public func buildUSBTopology(nodes: [USBSysfsNode],
                             netInterfaces: [String: String] = [:],
                             capacities: [String: UInt64] = [:],
                             hidUsages: [String: Set<Int>] = [:]) -> USBTopology {
    // 1. Interfaces, grouped by the device that owns them. Because the owner is matched as a
    //    whole directory name, a child device's interfaces can never leak into its parent's
    //    set — which is what makes composite-device classification correct.
    var ifaceClasses: [String: Set<Int>] = [:]
    var bootHID: [String: Set<Int>] = [:]
    for node in nodes {
        guard case .interface(let owner, _, _) = classifyUSBSysfsName(node.name) else { continue }
        guard let cls = usbHex(node.attributes["bInterfaceClass"]) else { continue }
        ifaceClasses[owner, default: []].insert(cls)
        // Boot-protocol HID is the sysfs-only fallback when /proc/bus/input/devices is absent.
        if cls == 0x03, usbHex(node.attributes["bInterfaceSubClass"]) == 0x01 {
            switch usbHex(node.attributes["bInterfaceProtocol"]) {
            case 0x01: bootHID[owner, default: []].insert(6)
            case 0x02: bootHID[owner, default: []].insert(2)
            default: break
            }
        }
    }

    // 2. One record per real device (root hubs become ports, not chips).
    struct Row { let name: String; let bus: Int; let path: [Int]; let dev: AttachedDevice }
    var rows: [Row] = []
    var emitted = Set<String>()

    for node in nodes {
        guard case .device(let nameBus, let path) = classifyUSBSysfsName(node.name) else { continue }
        let a = node.attributes
        let vid = usbHex(a["idVendor"]), pid = usbHex(a["idProduct"])
        // Neither id means the device vanished mid-walk; skip rather than emit a ghost.
        guard vid != nil || pid != nil else { continue }

        let bus = usbInt(a["busnum"]) ?? nameBus
        let deviceClass = usbHex(a["bDeviceClass"]) ?? 0
        let product = usbTrimmed(a["product"])
        let maxChild = usbInt(a["maxchild"]) ?? 0

        // Name: the product string, else a hub described by its protocol, else vid:pid —
        // which is what a deauthorized device with no descriptors lands on.
        let name: String
        if let p = product {
            name = p
        } else if deviceClass == 0x09 {
            switch usbHex(a["bDeviceProtocol"]) {
            case 0x03: name = "USB 3.0 Hub"
            case 0x01, 0x02: name = "USB 2.0 Hub"
            default: name = "USB Hub"
            }
        } else {
            name = String(format: "USB %04x:%04x", vid ?? 0, pid ?? 0)
        }

        var kind = USBDeviceKind.classifyUSB(
            name: name, deviceClass: deviceClass,
            interfaceClasses: ifaceClasses[node.name] ?? [],
            hidUsages: (bootHID[node.name] ?? []).union(hidUsages[node.name] ?? []))
        // Two Linux-only adjustments: a device with downstream ports IS a hub even when it
        // says nothing useful, and a device that owns a netdev is a network adapter (which
        // is the rule macOS uses too).
        if kind == .generic, maxChild > 0 { kind = .hub }
        if netInterfaces[node.name] != nil { kind = .network }

        rows.append(Row(name: node.name, bus: bus, path: path, dev: AttachedDevice(
            id: node.name,
            name: name,
            receptacle: bus,
            kind: kind,
            interfaceBSD: netInterfaces[node.name],
            parentID: nil,                       // filled in below, once the set is known
            vendorName: usbTrimmed(a["manufacturer"]),
            vendorID: vid,
            productID: pid,
            serial: usbTrimmed(a["serial"]),
            classCode: deviceClass,
            usbVersion: usbVersionLabel(a["version"]),
            linkSpeedBps: usbSpeedBps(a["speed"]),
            // MUST stay nil: AttachedDevice.speedLabel returns `detail` ahead of
            // linkSpeedBps, so anything here would replace "5 Gbps" in the Devices table.
            detail: nil,
            connection: "USB",
            capacityBytes: capacities[node.name])))
        emitted.insert(node.name)
    }

    // 3. Parents. A parent that is a root hub, or that wasn't emitted, resolves upward until
    //    an emitted ancestor is found — never leave a dangling parentID.
    var devices: [AttachedDevice] = []
    for row in rows {
        var parent = usbParentName(row.name)
        while let p = parent, !emitted.contains(p) { parent = usbParentName(p) }
        var d = row.dev
        d.parentID = parent
        devices.append(d)
    }

    // 4. Deterministic order — snapshots are meant to be reproducible, and a lexicographic
    //    sort misorders "1-1.10" against "1-1.2".
    let order = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, ($0.bus, $0.path)) })
    devices.sort { a, b in
        let x = order[a.id] ?? (0, []), y = order[b.id] ?? (0, [])
        if x.0 != y.0 { return x.0 < y.0 }
        for (p, q) in zip(x.1, y.1) where p != q { return p < q }
        return x.1.count < y.1.count
    }

    // 5. One port per bus that actually has devices. An empty bus would render as a bare
    //    chip with nothing under it. The root hub names its controller, which is what makes
    //    the chip honest: "USB Bus 1 (xHCI)" says emulated-or-real USB host controller, not
    //    "TB 1", which would claim Thunderbolt hardware that may not exist.
    var controllerOf: [Int: String] = [:]
    for node in nodes {
        guard case .rootHub(let bus) = classifyUSBSysfsName(node.name),
              let c = usbControllerShortName(node.attributes["product"]) else { continue }
        controllerOf[bus] = c
    }
    let buses = Set(devices.map(\.receptacle)).sorted()
    let ports = buses.map { bus in
        HardwarePort(id: bus, side: controllerOf[bus] ?? "", position: "",
                     // Deliberately empty: the engine draws port→interface wires from
                     // childBSDNames AND device→interface wires from interfaceBSD, so
                     // listing a USB NIC in both draws the same wire twice.
                     childBSDNames: [],
                     hasConnectedDevice: true,
                     connectionMedium: "USB",
                     title: "USB Bus \(bus)")
    }
    return USBTopology(devices: devices, ports: ports)
}

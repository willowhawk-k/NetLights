import Foundation

// Thunderbolt / USB4 topology from /sys/bus/thunderbolt/devices.
//
// Pure and in Core, for the established reasons: no shell on any Linux machine, so captured
// sysfs content asserted from macOS is the only test signal; and AttachedDevice/HardwarePort
// have no public init, so the assembly has to happen on this side of the module boundary.
//
// The directory name carries the whole classification signal:
//   "domain0"   one controller
//   "0-0"       that controller's HOST router — the machine itself, not a device
//   "0-1"       a device one hop out, on downstream port 1
//   "0-101"     a device two hops out (port 1, then port 1 of the device above)
//   "0-0:1.1"   a retimer, which is a cable component and never a device chip

/// Receptacle ids for Thunderbolt ports start here so they cannot collide with the USB
/// collector's, which uses the kernel's bus numbers (1, 2, 3…). The negative sentinels
/// (-1 Wi-Fi, -2 Displays, -3 Battery, -4 Bluetooth) are likewise out of range.
public let thunderboltPortIDBase = 100

public enum ThunderboltEntryKind: Equatable, Sendable {
    case domain(index: Int)              // "domain0"
    case hostRouter(domain: Int)         // "0-0" — the controller, not a device
    case router(domain: Int, hops: [Int])// "0-1", "0-101"
    case retimer                         // "0-0:1.1"
    case unknown
}

/// Classify a /sys/bus/thunderbolt/devices entry from its name.
public func thunderboltEntryKind(_ name: String) -> ThunderboltEntryKind {
    if name.contains(":") { return .retimer }
    if name.hasPrefix("domain") {
        let rest = name.dropFirst("domain".count)
        guard !rest.isEmpty, let n = Int(rest) else { return .unknown }
        return .domain(index: n)
    }
    guard let dash = name.firstIndex(of: "-"),
          let domain = Int(name[name.startIndex..<dash]) else { return .unknown }
    let routeText = String(name[name.index(after: dash)...])
    guard !routeText.isEmpty, let route = UInt64(routeText, radix: 16) else { return .unknown }
    let hops = thunderboltRouteHops(route)
    return hops.isEmpty ? .hostRouter(domain: domain) : .router(domain: domain, hops: hops)
}

/// The downstream port numbers from the host outward, decoded from the route string.
///
/// The route is a packed sequence of bytes, each the downstream adapter number of the next
/// hop, low byte first. Port 0 is a router's control adapter and can never be a hop, so a
/// zero byte terminates the path — which is also what makes "0-0" (route 0) the host router.
public func thunderboltRouteHops(_ route: UInt64) -> [Int] {
    var r = route, hops: [Int] = []
    while hops.count < 8 {
        let b = Int(r & 0xFF)
        if b == 0 { break }
        hops.append(b)
        r >>= 8
    }
    return hops
}

/// The sysfs name of the router one hop closer to the host, or nil for a first-hop device.
public func thunderboltParentName(_ name: String) -> String? {
    guard case .router(let domain, let hops) = thunderboltEntryKind(name), hops.count > 1 else {
        return nil
    }
    var route: UInt64 = 0
    for (i, hop) in hops.dropLast().enumerated() { route |= UInt64(hop) << (8 * i) }
    return "\(domain)-" + String(route, radix: 16)
}

/// `%#x` output ("0x8086"), with the kernel's quirk that a zero value prints as a bare "0".
public func thunderboltHexID(_ raw: String?) -> Int? {
    guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
    if t == "0" { return 0 }
    guard t.hasPrefix("0x") || t.hasPrefix("0X") else { return Int(t, radix: 16) }
    return Int(t.dropFirst(2), radix: 16)
}

/// "20.0 Gb/s" → bits per second, per lane.
public func thunderboltLaneSpeedBps(_ raw: String?) -> UInt64? {
    guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
          let first = t.split(separator: " ").first, let gbps = Double(first), gbps > 0
    else { return nil }
    return UInt64((gbps * 1_000_000_000).rounded())
}

/// generation → the bus label the Devices table shows. 4 is USB4, which is what the spec is
/// actually called at that generation; below that it is Thunderbolt N.
public func thunderboltGenerationLabel(_ raw: String?) -> String? {
    guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), let g = Int(t), g > 0
    else { return nil }
    return g >= 4 ? "USB4" : "Thunderbolt \(g)"
}

/// One /sys/bus/thunderbolt/devices entry as read from disk.
public struct ThunderboltNode: Equatable, Sendable {
    public let name: String
    public let attributes: [String: String]
    /// For a host router: the `usb4_port<N>` subdirectories, i.e. the physical receptacles.
    public let usb4Ports: [Int]
    /// DEVTYPE=thunderbolt_xdomain — a peer HOST (another machine over TB networking),
    /// not a peripheral. Distinguishable only via uevent; the name looks identical.
    public let isXDomain: Bool

    public init(name: String, attributes: [String: String],
                usb4Ports: [Int] = [], isXDomain: Bool = false) {
        self.name = name; self.attributes = attributes
        self.usb4Ports = usb4Ports; self.isXDomain = isXDomain
    }
}

public struct ThunderboltTopology {
    public var devices: [AttachedDevice]
    public var ports: [HardwarePort]
}

/// `DEVTYPE=thunderbolt_xdomain` in a uevent blob.
public func thunderboltIsXDomain(_ uevent: String?) -> Bool {
    guard let u = uevent else { return false }
    return u.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "DEVTYPE=thunderbolt_xdomain" }
}

/// Build the Thunderbolt device chips and their receptacles.
///
/// Unlike the USB collector, EMPTY ports are emitted too: a host router's `usb4_port<N>`
/// entries are real, enumerable physical receptacles, so showing an unoccupied Thunderbolt
/// port matches what the macOS graph does with a Mac's TB ports.
public func buildThunderboltTopology(nodes: [ThunderboltNode]) -> ThunderboltTopology {
    // 1. Receptacles: every usb4_port on every host router, plus any first hop actually in
    //    use (older kernels predate usb4_port entries, and a device must never be dropped
    //    for want of a port to hang it on).
    var receptacles = Set<Int>()               // packed (domain << 8) | port
    for node in nodes {
        if case .hostRouter(let domain) = thunderboltEntryKind(node.name) {
            for p in node.usb4Ports { receptacles.insert((domain << 8) | p) }
        }
        if case .router(let domain, let hops) = thunderboltEntryKind(node.name),
           let first = hops.first {
            receptacles.insert((domain << 8) | first)
        }
    }
    let ordered = receptacles.sorted()
    // Sequential 1-based numbering across sorted (domain, port), so the label reads like a
    // port number rather than exposing the packed key.
    var portID: [Int: Int] = [:]
    for (i, key) in ordered.enumerated() { portID[key] = thunderboltPortIDBase + i }

    var occupied = Set<Int>()
    var devices: [AttachedDevice] = []
    var emitted = Set<String>()

    // 2. Device chips: attached routers only. Host routers are the machine itself, retimers
    //    are cable components, domains are controllers — none is a peripheral.
    for node in nodes {
        guard case .router(let domain, let hops) = thunderboltEntryKind(node.name),
              let first = hops.first, let recep = portID[(domain << 8) | first] else { continue }
        occupied.insert(recep)
        let a = node.attributes
        func attr(_ k: String) -> String? {
            guard let v = a[k]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return v
        }
        let vendorName = attr("vendor_name")
        let name = attr("device_name")
            ?? vendorName.map { "\($0) Thunderbolt Device" }
            ?? "Thunderbolt Device"

        // A peer host is a computer; otherwise let the shared name classifier decide (it
        // already recognises "Dock"/"Hub"/"Display"/drive names), defaulting to a dock,
        // which is overwhelmingly what a Thunderbolt peripheral is.
        var kind: USBDeviceKind = .computer
        if !node.isXDomain {
            let byName = USBDeviceKind.classify(name: name, classCode: -1)
            kind = byName != .generic ? byName : .hub
        }

        // Speed is per-lane; two bonded lanes is what makes a "40 Gbps" TB3 link.
        let lanes = attr("rx_lanes").flatMap(Int.init) ?? attr("link_width").flatMap(Int.init) ?? 1
        let perLane = thunderboltLaneSpeedBps(attr("rx_speed") ?? attr("link_speed"))
        let speed = perLane.map { $0 * UInt64(max(min(lanes, 2), 1)) }

        // An unauthorized device is present but has no tunnel, which matters more than its
        // link rate — and `speedLabel` shows `detail` ahead of the rate, so this replaces it.
        let unauthorized = attr("authorized") == "0"

        devices.append(AttachedDevice(
            id: "tb-\(node.name)",
            name: name,
            receptacle: recep,
            kind: kind,
            parentID: thunderboltParentName(node.name).map { "tb-\($0)" },
            vendorName: vendorName,
            vendorID: thunderboltHexID(attr("vendor")),
            productID: thunderboltHexID(attr("device")),
            serial: attr("unique_id"),
            usbVersion: thunderboltGenerationLabel(attr("generation")),
            linkSpeedBps: unauthorized ? nil : speed,
            detail: unauthorized ? "Not authorized" : nil,
            connection: "Thunderbolt"))
        emitted.insert("tb-\(node.name)")
    }

    // Never leave a dangling parentID — a nested router whose parent was filtered out
    // becomes a root on its own receptacle.
    devices = devices.map { d in
        var d = d
        if let p = d.parentID, !emitted.contains(p) { d.parentID = nil }
        return d
    }
    devices.sort { $0.id < $1.id }

    let ports = ordered.compactMap { key -> HardwarePort? in
        guard let id = portID[key] else { return nil }
        let n = id - thunderboltPortIDBase + 1
        return HardwarePort(id: id, side: "", position: "",
                            childBSDNames: [],
                            hasConnectedDevice: occupied.contains(id),
                            connectionMedium: "Thunderbolt",
                            // Genuinely Thunderbolt here, so the default label would have
                            // been right — but the id is offset to avoid colliding with USB
                            // bus numbers, so it must be spelled out rather than derived.
                            title: "TB Port \(n)")
    }
    return ThunderboltTopology(devices: devices, ports: ports)
}

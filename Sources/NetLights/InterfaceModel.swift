import Foundation

// MARK: - Interface Type

enum InterfaceCategory: String, CaseIterable {
    case ethernet   = "Ethernet"
    case wifi       = "Wi-Fi"
    case awdl       = "AWDL"        // AirDrop/AirPlay wireless service
    case loopback   = "Loopback"
    case bridge     = "Bridge"
    case vlan       = "VLAN"
    case tunnel     = "Tunnel/VPN"
    case cellular   = "Cellular"
    case thunderbolt = "Thunderbolt" // TB bridge pseudo-ports (no real cable)
    case other      = "Other"

    var systemImage: String {
        switch self {
        case .ethernet:    return "cable.connector"
        case .wifi:        return "wifi"
        case .awdl:        return "airplayaudio"
        case .loopback:    return "arrow.triangle.2.circlepath"
        case .bridge:      return "arrow.triangle.branch"
        case .vlan:        return "square.stack.3d.up"
        case .tunnel:      return "lock.shield"
        case .cellular:    return "antenna.radiowaves.left.and.right"
        case .thunderbolt: return "bolt.fill"
        case .other:       return "network"
        }
    }

    var layerLabel: String {
        switch self {
        case .ethernet, .wifi, .cellular: return "Physical"
        case .thunderbolt:                return "Physical"
        case .bridge, .vlan:              return "Data Link"
        case .tunnel, .loopback, .awdl, .other: return "Virtual"
        }
    }
}

// MARK: - Link State

enum LinkState {
    case up, down, unknown
}

// MARK: - Interface Info

struct InterfaceInfo: Identifiable, Equatable {
    let id: String          // BSD name, e.g. "en0"
    var displayName: String? // Human name from SystemConfiguration, e.g. "Wi-Fi", "Thunderbolt 1"
    var category: InterfaceCategory
    var ipv4Addresses: [String]
    var ipv6Addresses: [String]
    var macAddress: String?
    var linkSpeedBps: UInt64?
    var linkState: LinkState
    var rxBytes: UInt64
    var txBytes: UInt64
    var mtu: Int
    var flags: UInt32

    // Computed
    var isUp: Bool { flags & 0x1 != 0 }  // IFF_UP
    var isRunning: Bool { flags & 0x40 != 0 }  // IFF_RUNNING
    // A port has "link" only when the sysctl reports both IFF_UP and IFF_RUNNING.
    // For TB virtual en* without a cable, IFF_RUNNING is 0 → hasLink = false.
    var hasLink: Bool { linkState == .up }

    var formattedSpeed: String? {
        guard let bps = linkSpeedBps, bps > 0 else { return nil }
        switch bps {
        case ..<1_000_000:       return "\(bps / 1000) Kbps"
        case ..<1_000_000_000:   return "\(bps / 1_000_000) Mbps"
        default:                 return "\(bps / 1_000_000_000) Gbps"
        }
    }

    var primaryIP: String? { ipv4Addresses.first }

    /// True when an interface has no current IP address — provisioned by the OS
    /// but not actively in use (e.g. un-configured utun tunnels, disconnected en*).
    /// We deliberately ignore cumulative byte counts: even idle tunnels accumulate
    /// setup bytes, so the count is not a reliable activity signal.
    var isUnused: Bool {
        ipv4Addresses.isEmpty
        && category != .loopback
        && category != .bridge
        && category != .vlan
    }

    /// Short human-readable label shown beneath the interface name in the graph node.
    var subtitleLabel: String {
        // Virtual app adapters: show the app name rather than a generic label
        if isVirtualAdapter { return virtualAdapterAppName }
        // Prefer IP address when present (most informative at a glance)
        if let ip = primaryIP { return ip }
        // Use SC hardware port name when available, with some shortening
        if let d = displayName {
            if d.lowercased().contains("thunderbolt bridge") { return "TB Bridge" }
            if d.lowercased().contains("thunderbolt")        { return d }   // "Thunderbolt 1" etc.
            if d.lowercased().contains("usb")                { return "USB Ethernet" }
            if d.lowercased().contains("wi-fi")              { return "Wi-Fi" }
            return d
        }
        // Fallback: derive from BSD interface name
        switch true {
        case id == "lo0":          return "Loopback"
        case id.hasPrefix("utun"): return "VPN Tunnel"
        case id.hasPrefix("anpi"): return "USB Network"
        case id.hasPrefix("awdl"): return "AirDrop"
        case id.hasPrefix("llw"):  return "Continuity"
        case id.hasPrefix("ap"):   return "Wi-Fi Sharing"
        case id == "pktap0":       return "Packet Tap"
        case id == "gif0":         return "Generic Tunnel"
        case id == "stf0":         return "IPv6-in-IPv4"
        case id.hasPrefix("ipsec"):return "IPSec Tunnel"
        case id.hasPrefix("vlan"): return "VLAN"
        case id.hasPrefix("bridge"): return "Bridge"
        default:                   return category.rawValue
        }
    }

    /// Thunderbolt port number parsed from SC display name, e.g. "Thunderbolt 1" → 1.
    /// Also works for "Ethernet Adapter (Thunderbolt 1)".
    var thunderboltPortNumber: Int? {
        guard let d = displayName else { return nil }
        // Simple scan: find the last digit-sequence that follows "Thunderbolt"
        let words = d.components(separatedBy: .whitespacesAndNewlines)
        for (i, word) in words.enumerated() {
            if word.lowercased().hasPrefix("thunderbolt"), i + 1 < words.count {
                let next = words[i + 1].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                if let n = Int(next) { return n }
            }
        }
        return nil
    }

    /// True when this interface is the Personal Hotspot tether (172.20.10.x IP).
    var isIPhoneHotspot: Bool {
        if displayName?.lowercased().contains("iphone") == true { return true }
        return ipv4Addresses.contains { $0.hasPrefix("172.20.10.") }
    }

    /// True when this interface is ANY of the virtual channels macOS creates for a
    /// USB-connected iPhone/iPad (tethering, USBMUX lockdown, CarPlay, etc.).
    /// macOS creates 2–3 en* interfaces per device; only one gets an IP (hotspot)
    /// while the others have no SC display name but share a locally-administered MAC.
    var isPhoneAssociated: Bool {
        if isVirtualAdapter { return false }
        if thunderboltPortNumber != nil { return false }
        let d = displayName?.lowercased() ?? ""
        if d.contains("iphone") || d.contains("ipad") || d.contains("apple mobile") { return true }
        if ipv4Addresses.contains(where: { $0.hasPrefix("172.20.10.") }) { return true }
        // Unnamed en* with locally-administered MAC (bit 1 of first byte set) = iPhone NCM channel.
        // These are the "other two" interfaces (USBMUX / lockdown) that never get an IP.
        if category == .ethernet && displayName == nil,
           let mac = macAddress,
           let fb = UInt8(String(mac.prefix(2)), radix: 16),
           fb & 0x02 != 0 { return true }
        return false
    }

    /// True when this interface is a virtual adapter created by an app (Parallels,
    /// VMware, a VPN client, etc.) rather than a real or TB-attached device.
    /// Detection: SC assigns "Ethernet Adapter (enX)" to such adapters.
    var isVirtualAdapter: Bool {
        guard thunderboltPortNumber == nil else { return false }
        let d = displayName?.lowercased() ?? ""
        return d.hasPrefix("ethernet adapter")
    }

    /// For virtual adapters: best-guess application name from MAC OUI.
    var virtualAdapterAppName: String {
        guard let mac = macAddress else { return "App Adapter" }
        let oui = String(mac.lowercased().prefix(8))
        switch oui {
        case "00:1c:42":            return "Parallels"
        case "00:0c:29", "00:50:56": return "VMware Fusion"
        case "08:00:27":            return "VirtualBox"
        default:                    return "VM / App Adapter"
        }
    }

    /// Effective icon — overrides category icon for special interface types.
    var effectiveSystemImage: String {
        if isIPhoneHotspot { return "iphone" }
        return category.systemImage
    }

    /// Ordering key used to sub-group interfaces within their layer band.
    var groupKey: String {
        if isVirtualAdapter { return "9-app-adapter" }  // separate group, after real Physical ones
        switch category {
        case .wifi:        return "0-wifi"
        case .ethernet:    return "1-ethernet"
        case .thunderbolt: return "2-thunderbolt"
        case .bridge:      return "0-bridge"
        case .vlan:        return "1-vlan"
        case .tunnel:      return "0-vpn"
        case .loopback:    return "1-loopback"
        case .awdl:        return "2-apple-wireless"
        case .cellular:    return "3-cellular"
        case .other:       return "4-other"
        }
    }

    static func == (lhs: InterfaceInfo, rhs: InterfaceInfo) -> Bool {
        lhs.id == rhs.id &&
        lhs.linkState == rhs.linkState &&
        lhs.rxBytes == rhs.rxBytes &&
        lhs.txBytes == rhs.txBytes &&
        lhs.ipv4Addresses == rhs.ipv4Addresses
    }
}

// MARK: - Route Entry

struct RouteEntry: Identifiable {
    let id = UUID()
    var destination: String
    var gateway: String
    var netmask: String?
    var interfaceName: String
    var isDefault: Bool
    var flags: String
}

// MARK: - Gateway Node

/// Represents a next-hop router visible in the routing table.
/// These are external to the machine — shown in the bottom "Gateways" band.
struct GatewayNode: Identifiable, Equatable {
    let id: String              // gateway IP address
    var isDefault: Bool         // appears as a default (0.0.0.0) route gateway
    var reachableVia: [String]  // BSD interface names that have a route to this gateway
    var isVPN: Bool = false      // gateway reached over a VPN/tunnel interface

    var systemImage: String {
        if isVPN { return isDefault ? "lock.shield.fill" : "lock.shield" }
        return isDefault ? "diamond.fill" : "diamond"
    }
    var label: String { isDefault ? "\(id) ✦" : id }
    var roleLabel: String {
        switch (isVPN, isDefault) {
        case (true, true):   return "VPN Default GW"
        case (true, false):  return "VPN Gateway"
        case (false, true):  return "Default GW"
        case (false, false): return "Gateway"
        }
    }
}

// MARK: - Hardware Port (L0 abstraction)

/// Represents a physical USB-C / Thunderbolt port slot on the machine chassis,
/// or a connected USB peripheral (iPhone/iPad, id = 0).
struct HardwarePort: Identifiable {
    let id: Int             // Thunderbolt port number (1-based); 0 = iPhone/iPad
    var side: String        // "Left", "Right", "Rear", or "" if unknown
    var position: String    // e.g. "Front", "Middle", "Rear" on that side, or ""
    var childBSDNames: [String]   // en* interfaces that belong to this port
    var hasConnectedDevice: Bool  // any child has link up
    var isPhone: Bool = false     // true for the virtual iPhone/iPad entry
    var physicalReceptacle: Int? = nil  // for iPhone: TB receptacle id it's plugged into
    var hasPower: Bool = false    // USB-C power (charger) attached to this port
}

// MARK: - Mac model → port layout

/// Returns known side/position info for a given `hw.model` identifier.
/// Returns nil for unknown models (graph still works, just without side labels).
func hardwarePortLayout(model: String) -> [Int: (side: String, position: String)] {
    switch model {

    // ── MacBook Pro 14-inch M4 (Mac16,6 = M4, Mac16,7 = M4 Pro/Max) ──────────
    // Left: MagSafe + TB Port 1 (front) + TB Port 2 (rear)
    // Right: TB Port 3 + HDMI 2.1 + SD
    case "Mac16,6", "Mac16,7":
        return [1: ("Left", "Front"), 2: ("Left", "Rear"), 3: ("Right", "")]

    // ── MacBook Pro 16-inch M4 (Mac16,8 = M4 Pro/Max) ────────────────────────
    // Left: MagSafe + TB Port 1 (front) + TB Port 2 (rear)
    // Right: TB Port 3 + HDMI 2.1 + SD
    case "Mac16,8":
        return [1: ("Left", "Front"), 2: ("Left", "Rear"), 3: ("Right", "")]

    // ── MacBook Pro 14-inch M3 (Mac15,6 = M3, Mac15,7 = M3 Pro, Mac15,8/9 = M3 Max) ──
    case "Mac15,6", "Mac15,7", "Mac15,8", "Mac15,9":
        return [1: ("Left", "Front"), 2: ("Left", "Rear"), 3: ("Right", "")]

    // ── MacBook Pro 16-inch M3 (Mac15,10/11 = M3 Pro/Max) ────────────────────
    case "Mac15,10", "Mac15,11":
        return [1: ("Left", "Front"), 2: ("Left", "Rear"), 3: ("Right", "")]

    // ── MacBook Pro 14-inch M2 Pro/Max (Mac14,9/10) ───────────────────────────
    // Left: MagSafe + 2 TB4, Right: 1 TB4 + HDMI + SD
    case "Mac14,9", "Mac14,10":
        return [1: ("Left", "Front"), 2: ("Left", "Rear"), 3: ("Right", "")]

    // ── MacBook Pro 16-inch M2 Pro/Max (Mac14,6/7) ───────────────────────────
    case "Mac14,6", "Mac14,7":
        return [1: ("Left", "Front"), 2: ("Left", "Rear"), 3: ("Right", "")]

    // ── MacBook Pro 14-inch M1 Pro/Max (MacBookPro18,3/4) ────────────────────
    // Same layout
    case "MacBookPro18,3", "MacBookPro18,4":
        return [1: ("Left", "Front"), 2: ("Left", "Rear"), 3: ("Right", "")]

    // ── MacBook Pro 16-inch M1 Pro/Max (MacBookPro18,1/2) ────────────────────
    case "MacBookPro18,1", "MacBookPro18,2":
        return [1: ("Left", "Front"), 2: ("Left", "Rear"), 3: ("Right", "")]

    // ── MacBook Air M2 (Mac14,2) / M3 (Mac15,12/13) — 2 left TB ports, no right ──
    case "Mac14,2", "Mac15,12", "Mac15,13":
        return [1: ("Left", "Front"), 2: ("Left", "Rear")]

    // ── Mac mini M4 (Mac16,10/11), M2 (Mac14,3/12), M1 (MacMini9,1) ─────────
    case "Mac16,10", "Mac16,11", "Mac14,3", "Mac14,12", "MacMini9,1":
        return [1: ("Rear", ""), 2: ("Rear", ""), 3: ("Rear", "")]

    // ── Mac Studio M2 (Mac14,13/14) / M1 (Mac13,1/2) ────────────────────────
    case "Mac14,13", "Mac14,14", "Mac13,1", "Mac13,2":
        return [1: ("Rear", ""), 2: ("Rear", ""), 3: ("Rear", ""), 4: ("Rear", "")]

    default:
        return [:]
    }
}

// MARK: - Traffic State (for LED blinking)

struct TrafficState {
    var rxActive: Bool = false
    var txActive: Bool = false
    var lastRx: UInt64 = 0
    var lastTx: UInt64 = 0
}

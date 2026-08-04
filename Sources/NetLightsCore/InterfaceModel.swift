import Foundation

// MARK: - Interface Type

public enum InterfaceCategory: String, CaseIterable, Codable {
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

public enum LinkState: String, Codable {
    case up, down, unknown
}

// MARK: - Interface Info

public struct InterfaceInfo: Identifiable, Equatable, Codable {
    public let id: String   // BSD name, e.g. "en0"
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

    // Explicit public init (mirrors the memberwise one, so macOS construction is
    // unchanged) — lets a separate module (the Linux collector) build interfaces.
    public init(id: String, displayName: String? = nil, category: InterfaceCategory,
                ipv4Addresses: [String] = [], ipv6Addresses: [String] = [],
                macAddress: String? = nil, linkSpeedBps: UInt64? = nil,
                linkState: LinkState = .unknown, rxBytes: UInt64 = 0, txBytes: UInt64 = 0,
                mtu: Int = 0, flags: UInt32 = 0) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.ipv4Addresses = ipv4Addresses
        self.ipv6Addresses = ipv6Addresses
        self.macAddress = macAddress
        self.linkSpeedBps = linkSpeedBps
        self.linkState = linkState
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.mtu = mtu
        self.flags = flags
    }

    // Computed
    var isUp: Bool { flags & 0x1 != 0 }  // IFF_UP
    var isRunning: Bool { flags & 0x40 != 0 }  // IFF_RUNNING
    // A port has "link" only when the sysctl reports both IFF_UP and IFF_RUNNING.
    // For TB virtual en* without a cable, IFF_RUNNING is 0 → hasLink = false.
    var hasLink: Bool { linkState == .up }

    var formattedSpeed: String? {
        guard let bps = linkSpeedBps, bps > 0 else { return nil }
        return formattedBitrate(bps)
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

    /// Whether to hide this interface in the "hide inactive" view: the usual unused
    /// test; OR a structurally-up-but-idle L2 bridge (always "up", rarely carrying
    /// anything) with no live traffic; OR a disconnected tunnel that kept a stale
    /// address after its VPN dropped (not linked-up, no live traffic — an active VPN
    /// sets IFF_UP+IFF_RUNNING so hasLink is true, so this never hides a live tunnel).
    /// `active` = has current rx/tx traffic.
    func isHiddenWhenInactive(active: Bool) -> Bool {
        isUnused
        || (category == .bridge && !active)
        || (category == .tunnel && !hasLink && !active)
    }

    /// Short human-readable label shown beneath the interface name in the graph node.
    var subtitleLabel: String {
        // Virtual app adapters: show the app name rather than a generic label
        if isVirtualAdapter { return virtualAdapterAppName }
        // iPhone USB channels: one carries Personal Hotspot, the others are the
        // link-local NCM channels macOS keeps up for device communication.
        if isPhoneAssociated {
            if ipv4Addresses.contains(where: { $0.hasPrefix("172.20.10.") }) { return "Personal Hotspot" }
            return "USB tether"
        }
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

    /// The band this interface renders in. Normally its category's OSI layer — EXCEPT a
    /// virtual (VM/app) adapter groups with the Virtual band even though it's an ethernet
    /// L2 interface: it has no hardware port, so it doesn't belong among the physical,
    /// port-backed links.
    var effectiveLayer: String { isVirtualAdapter ? "Virtual" : category.layerLabel }

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

    public static func == (lhs: InterfaceInfo, rhs: InterfaceInfo) -> Bool {
        lhs.id == rhs.id &&
        lhs.linkState == rhs.linkState &&
        lhs.rxBytes == rhs.rxBytes &&
        lhs.txBytes == rhs.txBytes &&
        lhs.ipv4Addresses == rhs.ipv4Addresses
    }
}

// MARK: - Route Entry

public struct RouteEntry: Identifiable, Codable {
    public let id = UUID()
    var destination: String
    var gateway: String
    var netmask: String?
    var interfaceName: String
    var isDefault: Bool
    var flags: String

    public init(destination: String, gateway: String, netmask: String? = nil,
                interfaceName: String, isDefault: Bool, flags: String) {
        self.destination = destination
        self.gateway = gateway
        self.netmask = netmask
        self.interfaceName = interfaceName
        self.isDefault = isDefault
        self.flags = flags
    }
}

// MARK: - Gateway Node

/// Represents a next-hop router visible in the routing table.
/// These are external to the machine — shown in the bottom "Gateways" band.
public struct GatewayNode: Identifiable, Equatable, Codable {
    public let id: String       // gateway IP address
    var isDefault: Bool         // appears as a default (0.0.0.0) route gateway
    var reachableVia: [String]  // BSD interface names that have a route to this gateway
    var isVPN: Bool = false      // gateway reached over a VPN/tunnel interface
    var networkName: String? = nil   // SSID / search domain (egress gateway), Option A
    var precedence: Int? = nil   // 1 = the winning default route, 2 = next, …
    var vpnCarrier: String? = nil // (VPN) physical interface the encrypted traffic egresses through
    var vpnServer: String? = nil  // (VPN) the concentrator's public IP the tunnel connects to

    var systemImage: String {
        if isVPN { return isDefault ? "lock.shield.fill" : "lock.shield" }
        return isDefault ? "diamond.fill" : "diamond"
    }
    var label: String { isDefault ? "\(id) ✦" : id }

    /// Primary chip label: "GW #1" / "VPN GW #2" — precedence makes the winner clear.
    var titleLabel: String {
        let base = isVPN ? "VPN GW" : "GW"
        if let p = precedence { return "\(base) #\(p)" }
        return base
    }

    /// Longer descriptor for tooltips (no "Default" noise).
    var roleLabel: String {
        if isVPN { return isDefault ? "VPN gateway" : "VPN next hop" }
        return isDefault ? "Gateway" : "Next hop"
    }
}

// MARK: - Hardware Port (L0 abstraction)

/// Represents a physical USB-C / Thunderbolt port slot on the machine chassis,
/// or a connected USB peripheral (iPhone/iPad, id = 0).
public struct HardwarePort: Identifiable, Codable {
    public let id: Int      // Thunderbolt port number (1-based); 0 = iPhone/iPad
    var side: String        // "Left", "Right", "Rear", or "" if unknown
    var position: String    // e.g. "Front", "Middle", "Rear" on that side, or ""
    var childBSDNames: [String]   // en* interfaces that belong to this port
    var hasConnectedDevice: Bool  // any child has link up
    var isPhone: Bool = false     // true for the virtual iPhone/iPad entry
    var deviceName: String = "iPhone"   // "iPhone" or "iPad" for the phone entry
    var physicalReceptacle: Int? = nil  // for iPhone: TB receptacle id it's plugged into
    var hasPower: Bool = false    // USB-C power (charger) attached to this port
    var deviceChildren: [String] = []  // BSD names of real USB devices on this port (vs TB-bridge pseudo-members)
    var connectionMedium: String = "USB-C"  // for iPhone: "USB-C" / "Wi-Fi" / "Bluetooth"
}

// MARK: - Egress (uplink to the outside world)

/// Describes how the machine reaches the internet — the last physical hop and,
/// when known, the network's identity (Wi-Fi SSID, wired search domain, …).
public struct EgressInfo: Equatable, Codable {
    enum Kind: String, Equatable, Codable {
        case wifi, wired, cellular, other
        var label: String {
            switch self {
            case .wifi:     return "Wi-Fi"
            case .wired:    return "Wired"
            case .cellular: return "Cellular"
            case .other:    return "Uplink"
            }
        }
        var systemImage: String {
            switch self {
            case .wifi:     return "wifi"
            case .wired:    return "cable.connector"
            case .cellular: return "antenna.radiowaves.left.and.right"
            case .other:    return "globe"
            }
        }
    }

    var viaInterface: String   // last physical hop, e.g. "en0"
    var kind: Kind
    var name: String?          // SSID / domain when known

    /// The network identity to show, falling back to the uplink type.
    var displayName: String { name ?? kind.label }
}

// MARK: - DNS resolvers

/// A DNS resolver set the system knows about — the synthesized *active* set
/// (`State:/Network/Global/DNS`) or one network service's set. VPNs and other
/// services frequently inject their own resolvers, so surfacing every set — and
/// which one actually wins — is the troubleshooting value. Read from SCDynamicStore:
/// in-process, privilege-free, sandbox-safe (same store the egress/service-order
/// lookups already use).
public struct DNSConfig: Identifiable, Equatable, Codable {
    public let id: String          // "global", or the network service id
    var scopeLabel: String         // "Active resolvers", a service name, or an interface
    var interfaceName: String?     // interface the set is bound to (en0, utun3), when known
    var servers: [String]          // resolver addresses, in query order
    var searchDomains: [String]
    var domainName: String?
    var matchDomains: [String]     // SupplementalMatchDomains — split-DNS scoping (VPNs)
    var isPrimary: Bool            // this service is the OS primary (its DNS becomes global)
    var isGlobal: Bool             // the synthesized "active" set (State:/Network/Global/DNS)
    var userNamedScope: Bool       // scopeLabel came from a user-defined service name (redact in privacy mode)

    public init(id: String, scopeLabel: String, interfaceName: String? = nil,
                servers: [String] = [], searchDomains: [String] = [], domainName: String? = nil,
                matchDomains: [String] = [], isPrimary: Bool = false, isGlobal: Bool = false,
                userNamedScope: Bool = false) {
        self.id = id
        self.scopeLabel = scopeLabel
        self.interfaceName = interfaceName
        self.servers = servers
        self.searchDomains = searchDomains
        self.domainName = domainName
        self.matchDomains = matchDomains
        self.isPrimary = isPrimary
        self.isGlobal = isGlobal
        self.userNamedScope = userNamedScope
    }

    /// A split-DNS set: it answers only the domains in `matchDomains`, not every query.
    var isSupplemental: Bool { !matchDomains.isEmpty }
}

// MARK: - System power (AC / charging)

/// SYSTEM-level power state from AppleSmartBattery. macOS exposes no per-port
/// power direction, so this is intentionally not tied to any USB-C port.
public struct SystemPower: Equatable, Codable {
    var onAC: Bool
    var charging: Bool
    var fullyCharged: Bool
    var level: Int?            // battery charge %
    var watts: Int?            // adapter wattage
    var adapterName: String?   // identified-adapter name (e.g. "140W USB-C Power Adapter")

    /// Status-bar label, or nil when nothing noteworthy (on battery, not charging).
    var label: String? {
        guard onAC else { return nil }
        let w = watts.map { " · \($0)W" } ?? ""
        return (charging ? "Charging" : "On AC power") + w
    }

    /// Short state word for the battery entity: distinguishes "plugged in & charging"
    /// from "plugged in but running off the adapter at full" from "on battery".
    var stateLabel: String {
        if !onAC { return "On battery" }
        if charging { return "Charging" }
        return "Powered"
    }

    /// Adapter descriptor for the entity / hover — the identified name when macOS
    /// exposes it (Apple adapters), else just the wattage (generic / dock PD source).
    /// We can't tell MagSafe from USB-C (electrically identical), so we never claim it.
    var adapterLabel: String? {
        guard onAC else { return nil }
        if let n = adapterName, !n.isEmpty { return n }
        return watts.map { "\($0)W adapter" }
    }
}

// MARK: - Attached USB device (non-network peripherals)

/// Classification of a USB device attached to a hardware port, for iconography.
public enum USBDeviceKind: String, Codable {
    case audio, storage, hub, keyboard, pointing, gamecontroller, display, camera, battery, network, computer, generic

    var systemImage: String {
        switch self {
        case .audio:          return "headphones"
        case .storage:        return "externaldrive.fill"
        case .hub:            return "point.3.connected.trianglepath.dotted"
        case .keyboard:       return "keyboard.fill"
        case .pointing:       return "computermouse.fill"
        case .gamecontroller: return "gamecontroller.fill"
        case .display:        return "display"
        case .camera:         return "camera.fill"
        case .battery:        return "battery.100.bolt"
        case .network:        return "antenna.radiowaves.left.and.right"
        case .computer:       return "laptopcomputer"
        case .generic:        return "cube.box.fill"
        }
    }

    var label: String {
        switch self {
        case .audio:          return "Audio"
        case .storage:        return "Storage"
        case .hub:            return "Hub / Dock"
        case .keyboard:       return "Keyboard"
        case .pointing:       return "Pointing"
        case .gamecontroller: return "Game Controller"
        case .display:        return "Display"
        case .camera:         return "Camera"
        case .battery:        return "Battery"
        case .network:        return "Network"
        case .computer:       return "Mac"
        case .generic:        return "USB Device"
        }
    }

    /// Best-guess classification from a USB product name and device class code.
    static func classify(name: String, classCode: Int) -> USBDeviceKind {
        let n = name.lowercased()
        if n.contains("airpod") || n.contains("headphone") || n.contains("buds")
            || n.contains("speaker") || n.contains("audio") || n.contains("beats") { return .audio }
        if n.contains("keyboard") { return .keyboard }
        if n.contains("mouse") || n.contains("trackpad") || n.contains("touchpad") { return .pointing }
        if n.contains("ssd") || n.contains("disk") || n.contains("drive")
            || n.contains("storage") || n.contains("t7") || n.contains("flash") { return .storage }
        if n.contains("hub") || n.contains("dock") { return .hub }
        // Check camera/webcam BEFORE display: a monitor's built-in webcam often
        // carries the display's name (e.g. "DELL Display 4MP Webcam").
        if n.contains("camera") || n.contains("webcam") { return .camera }
        if n.contains("display") || n.contains("monitor") || n.contains("hdmi") { return .display }
        if n.contains("battery") || n.contains("power bank") || n.contains("mophie") { return .battery }
        switch classCode {
        case 0x08: return .storage
        case 0x09: return .hub
        case 0x01: return .audio
        case 0x0E: return .camera
        default:   return .generic
        }
    }

    /// Kind from a device's set of HID Generic-Desktop top-level usages (page 1).
    /// A composite gaming mouse exposes BOTH a mouse and a (macro) keyboard usage,
    /// so mouse wins the tie; joystick/gamepad map to a game controller. nil when
    /// no usage maps, so other signals can decide.
    static func classifyHIDUsages(_ usages: Set<Int>) -> USBDeviceKind? {
        if usages.contains(2) || usages.contains(1) { return .pointing }        // Mouse, Pointer
        if usages.contains(6) || usages.contains(7) { return .keyboard }        // Keyboard, Keypad
        if usages.contains(4) || usages.contains(5) { return .gamecontroller }  // Joystick, Gamepad
        return nil
    }

    /// Classification for a USB device from its interface descriptors + HID usages,
    /// which is the only reliable signal for COMPOSITE devices (bDeviceClass 0 — a
    /// headset, gaming mouse, joystick, etc. all report 0 at the device level). The
    /// product name wins when it states the type; interface classes resolve the rest.
    static func classifyUSB(name: String, deviceClass: Int,
                            interfaceClasses: Set<Int>, hidUsages: Set<Int>) -> USBDeviceKind {
        // 1. An explicit name ("…Keyboard", "…Hub", "…Webcam") is most reliable.
        let byName = classify(name: name, classCode: -1)   // -1 → name-only (no class match)
        if byName != .generic { return byName }
        // 2. Interface descriptors reveal a composite device's real function.
        //    Video before Audio: webcams carry an audio (mic) interface too.
        if interfaceClasses.contains(0x0E) { return .camera }
        if interfaceClasses.contains(0x01) { return .audio }
        if interfaceClasses.contains(0x03), let k = classifyHIDUsages(hidUsages) { return k }
        if interfaceClasses.contains(0x08) { return .storage }
        if interfaceClasses.contains(0x09) { return .hub }
        // 3. Device-level class as a last resort.
        return classify(name: name, classCode: deviceClass)
    }

    /// Classification from a Bluetooth Class-of-Device (major/minor). The major
    /// class gives the broad category; for peripherals (arbitrary names) we prefer
    /// the name, then fall back to the keyboard/pointing minor bits.
    static func classifyBluetooth(major: Int, minor: Int, name: String) -> USBDeviceKind {
        switch major {
        case 0x04: return .audio        // Audio/Video — headset, headphones, speaker
        case 0x06: return .camera       // Imaging
        case 0x05:                      // Peripheral — keyboard / mouse / trackpad / …
            let byName = classify(name: name, classCode: 0)
            if byName != .generic { return byName }
            switch minor & 0x30 {
            case 0x10:        return .keyboard
            case 0x20, 0x30:  return .pointing
            default:          return .generic
            }
        default:
            return classify(name: name, classCode: 0)
        }
    }
}

/// A non-network USB peripheral attached to a hardware port (shown as a device chip).
public struct AttachedDevice: Identifiable, Equatable, Codable {
    public let id: String // stable per device (locationID)
    var name: String
    var receptacle: Int   // physical port id it's plugged into (-1 Wi-Fi, -2 Displays)
    var kind: USBDeviceKind
    var interfaceBSD: String? = nil   // the network interface it provides (e.g. MiFi → en10)
    var parentID: String? = nil       // the USB hub/dock this device hangs off, if any

    // Richer attributes for the Devices table (filled where the source exposes them).
    var vendorName: String? = nil     // manufacturer (USB vendor string / display PnP)
    var vendorID: Int? = nil          // USB idVendor
    var productID: Int? = nil         // USB idProduct
    var serial: String? = nil         // USB serial number
    var classCode: Int? = nil         // USB bDeviceClass
    var usbVersion: String? = nil     // e.g. "USB 2.1" (from bcdUSB)
    var linkSpeedBps: UInt64? = nil   // negotiated USB link speed (UsbLinkSpeed)
    var detail: String? = nil         // displays: "5120 × 2160 @ 100 Hz"
    var connection: String = "USB"    // "USB" / "Display" / "Bluetooth" / "Thunderbolt" (storage interconnect)
    var batteryPercent: Int? = nil    // device battery %, where the OS reports it (BT HID)
    var capacityBytes: UInt64? = nil  // storage devices: whole-disk capacity

    var systemImage: String { kind.systemImage }
    var isNetwork: Bool { interfaceBSD != nil }
    var batteryLabel: String? { batteryPercent.map { "\($0)%" } }

    /// Whole-disk capacity, decimal (drives are marketed in powers of 1000).
    var capacityLabel: String? {
        guard let b = capacityBytes, b > 0 else { return nil }
        return formatDiskCapacity(b)
    }

    /// Bus / link type, for the Devices table.
    var connectionLabel: String {
        switch connection {
        case "Display":   return "Display"
        case "Bluetooth": return "Bluetooth"
        default:          return usbVersion ?? connection   // "USB", or a storage interconnect (Thunderbolt)
        }
    }

    /// Throughput/capability: storage capacity, USB link speed, or a display's resolution/refresh.
    var speedLabel: String {
        if kind == .storage { return capacityLabel ?? "—" }
        if let d = detail { return d }
        guard let b = linkSpeedBps, b > 0 else { return "—" }
        return formattedBitrate(b)
    }

    var classLabel: String {
        if connection == "Display" { return "Display" }
        if connection == "Bluetooth" { return kind.label }
        if let c = classCode { return usbClassName(c) }
        return "—"
    }

    /// Vendor:product (USB) or serial — a stable identifier for the table.
    var idLabel: String {
        if let v = vendorID, let p = productID { return String(format: "%04x:%04x", v, p) }
        return serial ?? "—"
    }

    public static func == (l: AttachedDevice, r: AttachedDevice) -> Bool {
        l.id == r.id && l.name == r.name && l.receptacle == r.receptacle
            && l.interfaceBSD == r.interfaceBSD && l.parentID == r.parentID
            && l.batteryPercent == r.batteryPercent
    }
}

/// Human label for a USB `bDeviceClass` code (base class only).
func usbClassName(_ code: Int) -> String {
    switch code {
    case 0x00: return "Composite"
    case 0x01: return "Audio"
    case 0x02: return "Comm (CDC)"
    case 0x03: return "HID"
    case 0x05: return "Physical"
    case 0x06: return "Imaging"
    case 0x07: return "Printer"
    case 0x08: return "Mass Storage"
    case 0x09: return "Hub"
    case 0x0A: return "CDC Data"
    case 0x0B: return "Smart Card"
    case 0x0D: return "Content Sec."
    case 0x0E: return "Video"
    case 0x0F: return "Healthcare"
    case 0x10: return "A/V"
    case 0xDC: return "Diagnostic"
    case 0xE0: return "Wireless"
    case 0xEF: return "Miscellaneous"
    case 0xFE: return "App-Specific"
    case 0xFF: return "Vendor-Specific"
    default:   return String(format: "Class 0x%02X", code)
    }
}

// MARK: - Mac model → port layout

/// Returns known side/position info for a given `hw.model` identifier.
/// Returns nil for unknown models (graph still works, just without side labels).
func hardwarePortLayout(model: String) -> [Int: (side: String, position: String)] {
    switch model {

    // ── MacBook Pro 14-inch M4 (Mac16,6 = M4, Mac16,7 = M4 Pro/Max) ──────────
    // Left: MagSafe + TB Port 1 (front) + TB Port 2 (rear)
    // Right: TB Port 3 + HDMI 2.1 + SD
    // Verified on Mac16,7: receptacle 1 is the *rear* left port, 2 the *front* left.
    case "Mac16,6", "Mac16,7":
        return [1: ("Left", "Rear"), 2: ("Left", "Front"), 3: ("Right", "")]

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

public struct TrafficState: Codable {
    var rxActive: Bool = false
    var txActive: Bool = false
    var lastRx: UInt64 = 0
    var lastTx: UInt64 = 0
    // Smoothed throughput (bytes/sec) derived from rx/tx counter deltas. Drives
    // the on-wire numbers and the link hover; an EMA keeps them from jittering.
    var rxRate: Double = 0
    var txRate: Double = 0
}

// MARK: - Throughput / byte formatting (shared)

/// Below this many bytes/sec a link reads as idle — no number is shown.
/// (1024 B/s ≈ 8 Kbps.)
let trafficNoiseFloor: Double = 1024

// Throughput is shown in BITS per second (Kbps/Mbps/Gbps) — the networking
// convention, matching the negotiated link speed. Input is the byte-counter rate;
// we convert ×8 and use decimal (1000) magnitudes, as link/data rates are decimal.
// (Cumulative volume — Received/Sent — stays in bytes; see formatByteCount.)

/// A negotiated link rate from bits-per-second, in networking units. Whole where the
/// rate is whole (1 Gbps, 100 Mbps, 10 Gbps); one decimal only where a standard rate
/// needs it (2.5 Gbps, or a fractional Wi-Fi rate). Avoids the integer-division
/// truncation that used to render 2.5 Gbps (2_500_000_000 bps) as "2 Gbps".
func formattedBitrate(_ bps: UInt64) -> String {
    func trim(_ value: Double, _ unit: String) -> String {
        let s = value == value.rounded() ? String(format: "%.0f", value)
                                         : String(format: "%.1f", value)
        return "\(s) \(unit)"
    }
    switch bps {
    case ..<1_000_000:       return "\(bps / 1000) Kbps"
    case ..<1_000_000_000:   return trim(Double(bps) / 1_000_000, "Mbps")
    default:                 return trim(Double(bps) / 1_000_000_000, "Gbps")
    }
}

/// Full throughput label in bits/sec, e.g. "98.4 Mbps". nil below the noise floor.
func formatRate(_ bytesPerSec: Double) -> String? {
    guard bytesPerSec >= trafficNoiseFloor else { return nil }
    let kbps = bytesPerSec * 8 / 1000
    if kbps < 1000 { return String(format: "%.0f Kbps", kbps) }
    let mbps = kbps / 1000
    if mbps < 1000 { return String(format: mbps < 10 ? "%.1f Mbps" : "%.0f Mbps", mbps) }
    return String(format: "%.2f Gbps", mbps / 1000)
}

/// Compact bits/sec for drawing on the wire, e.g. "98Mbps", "850Kbps". nil if idle.
func formatRateShort(_ bytesPerSec: Double) -> String? {
    guard bytesPerSec >= trafficNoiseFloor else { return nil }
    let kbps = bytesPerSec * 8 / 1000
    if kbps < 1000 { return String(format: "%.0fKbps", kbps) }
    let mbps = kbps / 1000
    if mbps < 1000 { return String(format: mbps < 10 ? "%.1fMbps" : "%.0fMbps", mbps) }
    return String(format: "%.1fGbps", mbps / 1000)
}

/// Cumulative byte total, e.g. "1.4 GB".
func formatByteCount(_ n: UInt64) -> String {
    switch n {
    case ..<1024:          return "\(n) B"
    case ..<1_048_576:     return String(format: "%.1f KB", Double(n) / 1024)
    case ..<1_073_741_824: return String(format: "%.1f MB", Double(n) / 1_048_576)
    default:               return String(format: "%.2f GB", Double(n) / 1_073_741_824)
    }
}

/// Storage capacity in decimal units (drives are marketed in powers of 1000, so a
/// "1 TB" disk is 1,000,000,000,000 bytes — not the binary GiB `formatByteCount` uses).
func formatDiskCapacity(_ bytes: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB", "PB"]
    var v = Double(bytes), i = 0
    while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
    // One decimal below 10 (1.5 TB), whole above — and drop a bare ".0" (1 TB, not 1.0 TB).
    let n = String(format: (i > 0 && v < 10) ? "%.1f" : "%.0f", v)
    return "\(n.hasSuffix(".0") ? String(n.dropLast(2)) : n) \(units[i])"
}

// MARK: - Topology snapshot (the cross-platform contract)

/// A platform-neutral, serializable snapshot of everything the graph draws at one
/// instant. This is THE contract between a platform-specific collector (macOS
/// IOKit/sysctl/SCDynamicStore, Linux /sys·netlink·D-Bus, …) and the shared layout +
/// rendering layers — the single artifact every platform agrees on. `Codable` so it can
/// cross a process/socket boundary (a Linux collector → a web renderer), be captured for
/// tests, or dumped as JSON. Live throughput is NOT stored here: it's derived from each
/// interface's cumulative `rxBytes`/`txBytes` by a stateful rate deriver, per platform.
public struct TopologySnapshot: Codable {
    public var schemaVersion: Int = 1
    public var machineModel: String     // hw.model (macOS) / DMI product name (Linux); "" if unknown
    public var interfaces: [InterfaceInfo] = []
    public var routes: [RouteEntry] = []
    public var gateways: [GatewayNode] = []
    public var hardwarePorts: [HardwarePort] = []
    public var attachedDevices: [AttachedDevice] = []
    public var egress: EgressInfo? = nil
    public var systemPower: SystemPower? = nil
    public var dnsConfigs: [DNSConfig] = []

    // Explicit public init mirrors the (otherwise internal) memberwise init exactly, so
    // macOS construction is unchanged while a separate module (the Linux CLI) can build
    // a snapshot too.
    public init(schemaVersion: Int = 1, machineModel: String,
                interfaces: [InterfaceInfo] = [], routes: [RouteEntry] = [],
                gateways: [GatewayNode] = [], hardwarePorts: [HardwarePort] = [],
                attachedDevices: [AttachedDevice] = [], egress: EgressInfo? = nil,
                systemPower: SystemPower? = nil, dnsConfigs: [DNSConfig] = []) {
        self.schemaVersion = schemaVersion
        self.machineModel = machineModel
        self.interfaces = interfaces
        self.routes = routes
        self.gateways = gateways
        self.hardwarePorts = hardwarePorts
        self.attachedDevices = attachedDevices
        self.egress = egress
        self.systemPower = systemPower
        self.dnsConfigs = dnsConfigs
    }
}

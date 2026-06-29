import Foundation
import Combine
import Darwin
import SystemConfiguration
import CoreWLAN

// MARK: - NetworkMonitor

@MainActor
final class NetworkMonitor: ObservableObject {
    @Published var interfaces: [InterfaceInfo] = []
    @Published var routes: [RouteEntry] = []
    @Published var gateways: [GatewayNode] = []
    @Published var hardwarePorts: [HardwarePort] = []
    @Published var attachedDevices: [AttachedDevice] = []
    @Published var egress: EgressInfo?
    /// True when the "Check Location Privacy Settings" Help item should be enabled:
    /// the Mac has Wi-Fi hardware AND Location isn't authorized (so the SSID can't
    /// be read). Gating on actual authorization — not a nil SSID — avoids enabling
    /// the item on Ethernet-only / Wi-Fi-off Macs where Location was never the issue.
    @Published var locationHelpAvailable: Bool = false
    /// Whether the "Check Bluetooth Permission" menu item is actionable: the feature
    /// is active (usage string present) but no Bluetooth devices are showing yet —
    /// so the user may need to grant access (or nothing's connected). Greyed once
    /// devices appear, since access is then clearly working. (Derived from the
    /// @Published attachedDevices, so the menu updates as devices come and go.)
    var bluetoothHelpAvailable: Bool {
        BluetoothProbe.available && !attachedDevices.contains { $0.receptacle == -4 }
    }
    /// System AC/charging state (NOT per-port). nil on battery-less Macs.
    @Published var systemPower: SystemPower?
    @Published var serviceRank: [String: Int] = [:]   // interface → macOS service-order rank
    @Published var trafficStates: [String: TrafficState] = [:]

    let macModel: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }()

    private var pollTimer: Timer?
    private var trafficClearTimers: [String: Timer] = [:]
    private var previousBytes: [String: (rx: UInt64, tx: UInt64)] = [:]
    // Monotonic timestamp (seconds) of the last byte-counter sample, used to turn
    // rx/tx deltas into a per-second throughput rate. Uses a sleep-INCLUSIVE clock
    // (CLOCK_MONOTONIC_RAW) so a post-sleep gap reads as a large dt and is skipped,
    // rather than the awake-only systemUptime which freezes during sleep and would
    // divide a sleep-sized byte delta by a tiny dt (a false spike).
    private var lastTrafficSample: Double = 0
    private let locationAuth = LocationAuth()

    func start() {
        // Idempotent: the monitor is app-scoped (owned by NetLightsApp) and may be
        // started from more than one window's onAppear — only the first call arms
        // the poll timer, so a second window can't orphan/duplicate it.
        guard pollTimer == nil else { return }
        // Ask for Location access solely to read the Wi-Fi SSID (see LocationAuth);
        // re-refresh when the grant lands so the network name appears.
        locationAuth.onAuthorizationChange = { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        locationAuth.request()
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        // Tear down everything start() established (the monitor outlives any single
        // window now, so leaving these live would keep firing on a "stopped" monitor).
        locationAuth.onAuthorizationChange = nil
        trafficClearTimers.values.forEach { $0.invalidate() }
        trafficClearTimers.removeAll()
    }

    func refresh() {
        let newInterfaces = Self.gatherInterfaces()
        updateTrafficStates(newInterfaces: newInterfaces)
        interfaces = newInterfaces
        let newRoutes = Self.gatherRoutes()
        routes = newRoutes
        var newGateways = Self.buildGatewayNodes(from: newRoutes, interfaces: newInterfaces)
        let newEgress = Self.computeEgress(routes: newRoutes, interfaces: newInterfaces)
        // Option A: tag the egress gateway with the network's name (SSID/domain).
        if let e = newEgress,
           let gi = newGateways.firstIndex(where: {
               $0.isDefault && !$0.isVPN && $0.reachableVia.contains(e.viaInterface)
           }) {
            newGateways[gi].networkName = e.name
        }
        gateways = newGateways
        egress = newEgress
        // The Location Help item is useful only on a Wi-Fi Mac whose SSID is blocked
        // by Location authorization — not when there's simply no Wi-Fi association.
        let wifiPresent = newInterfaces.contains { $0.category == .wifi }
        locationHelpAvailable = wifiPresent && !locationAuth.isAuthorized
        serviceRank = Self.serviceOrder()

        // Build hardware ports immediately from the *cached* port status so the
        // UI never blocks. The actual TB/USB query (system_profiler + ioreg) is
        // slow — run it off the main thread and refresh the cache when it lands.
        hardwarePorts = Self.buildHardwarePorts(from: newInterfaces,
                                                macModel: macModel,
                                                portStatus: lastPortStatus)
        attachedDevices = lastPortStatus.attachedDevices
        systemPower = lastPortStatus.systemPower

        // Re-query topology roughly every ~5s, and never run two at once.
        portQueryCounter += 1
        if (portQueryCounter == 1 || portQueryCounter % 7 == 0) && !portQueryInFlight {
            portQueryInFlight = true
            let model = macModel
            // NSScreen names must be read on the main actor; capture them here and
            // hand them to the off-main IOKit/CoreGraphics port query.
            let displayNames = IOKitProbe.displayNames()
            // IOBluetooth's classic API wants the main run loop and goes through
            // bluetoothd over XPC, so refresh the connected-device list on a slower
            // cadence (every 4th port query, ~21s) and reuse the cache in between —
            // connection state changes rarely, and this keeps IPC off the hot path.
            btRefreshTick += 1
            if btRefreshTick % 4 == 1 { btDevicesCache = BluetoothProbe.connectedDevices() }
            let bluetooth = btDevicesCache
            Task.detached(priority: .utility) {
                let status = NetworkMonitor.queryPortStatus(displayNames: displayNames, bluetooth: bluetooth)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.lastPortStatus = status
                    self.portQueryInFlight = false
                    // Rebuild against the freshest interface list.
                    self.hardwarePorts = NetworkMonitor.buildHardwarePorts(
                        from: self.interfaces, macModel: model, portStatus: status)
                    self.attachedDevices = status.attachedDevices
                    self.systemPower = status.systemPower
                }
            }
        }
    }

    private var portQueryCounter = 0
    private var portQueryInFlight = false
    // Bluetooth device list cache (refreshed less often than the port query; see refresh()).
    private var btRefreshTick = 0
    private var btDevicesCache: [BluetoothProbe.RawBT] = []
    private var lastPortStatus: PortStatus = PortStatus()

    struct PortStatus {
        /// Receptacle number → true if a *Thunderbolt* device is connected.
        var tbConnected: [Int: Bool] = [:]
        /// Receptacle number → human-readable USB device name (e.g. "iPhone").
        var usbDeviceName: [Int: String] = [:]
        /// Physical receptacle the iPhone/iPad is plugged into, if any.
        var phoneReceptacle: Int? = nil
        /// "iPhone" or "iPad" — the connected mobile device kind (USB-detected).
        var phoneDeviceKind: String = "iPhone"
        /// Port number → true if anything is physically attached (cable/device/power),
        /// from the USB-C PD controller (AppleHPM). Authoritative connection signal.
        var hpmConnected: [Int: Bool] = [:]
        /// Port number → true if USB-C power (a charger) is attached.
        var hpmPower: [Int: Bool] = [:]
        /// USB-attached network interface BSD name → physical receptacle id.
        var deviceReceptacle: [String: Int] = [:]
        /// Non-network USB peripherals attached to ports (audio, storage, …).
        var attachedDevices: [AttachedDevice] = []
        /// System-level AC/charging state (NOT per-port — macOS exposes no per-port
        /// power direction). nil on Macs without a battery.
        var systemPower: SystemPower? = nil
    }

    // MARK: - Traffic LED logic

    private func updateTrafficStates(newInterfaces: [InterfaceInfo]) {
        let now = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
        let dt = lastTrafficSample > 0 ? now - lastTrafficSample : 0
        lastTrafficSample = now
        // EMA weight: blends each sample with the previous rate so the on-wire
        // number tracks real throughput without flickering between polls.
        let alpha = 0.5

        for iface in newInterfaces {
            let prev = previousBytes[iface.id]
            var state = trafficStates[iface.id] ?? TrafficState()

            if let prev = prev {
                if iface.rxBytes > prev.rx {
                    state.rxActive = true
                    scheduleTrafficClear(name: iface.id)
                }
                if iface.txBytes > prev.tx {
                    state.txActive = true
                    scheduleTrafficClear(name: iface.id)
                }
                // Only compute a rate over a sane window. Too short (an off-cadence
                // manual Refresh landing just after a timer tick) would project a
                // sub-second burst to a per-second figure; too long (first sample
                // after sleep/wake — systemUptime is frozen while asleep — or a
                // stalled timer) would divide a large byte delta by a tiny dt and
                // spike. Either way we skip the rate this sample; previousBytes is
                // still re-baselined below, so the next normal tick recomputes clean.
                if dt > 0.4 && dt < 5 {
                    // Guard against counter resets (interface re-added) and wraps.
                    let dRx = iface.rxBytes >= prev.rx ? Double(iface.rxBytes - prev.rx) : 0
                    let dTx = iface.txBytes >= prev.tx ? Double(iface.txBytes - prev.tx) : 0
                    state.rxRate = state.rxRate * (1 - alpha) + (dRx / dt) * alpha
                    state.txRate = state.txRate * (1 - alpha) + (dTx / dt) * alpha
                }
            }
            state.lastRx = iface.rxBytes
            state.lastTx = iface.txBytes
            trafficStates[iface.id] = state
            previousBytes[iface.id] = (iface.rxBytes, iface.txBytes)
        }
    }

    private func scheduleTrafficClear(name: String) {
        trafficClearTimers[name]?.invalidate()
        // 5s window: keeps a line continuously lit during sustained traffic even
        // when an interface reports its byte counters in bursts (e.g. iPhone USB
        // NCM / tunnel interfaces), without blinking. Dims 5s after traffic stops.
        trafficClearTimers[name] = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.trafficStates[name]?.rxActive = false
                self?.trafficStates[name]?.txActive = false
            }
        }
    }

    // MARK: - Interface gathering via getifaddrs + sysctl

    static func gatherInterfaces() -> [InterfaceInfo] {
        // Query SystemConfiguration for human-readable hardware port names.
        // This lets us tell "Wi-Fi" from "Thunderbolt Bridge" for en* interfaces.
        let scDisplayNames = buildSCDisplayNames()

        var ifaPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaPtr) == 0, let start = ifaPtr else { return [] }
        defer { freeifaddrs(start) }

        var byName: [String: InterfaceInfo] = [:]

        var ptr: UnsafeMutablePointer<ifaddrs>? = start
        while let ifa = ptr {
            let name = String(cString: ifa.pointee.ifa_name)
            let flags = ifa.pointee.ifa_flags
            let family = ifa.pointee.ifa_addr?.pointee.sa_family ?? 0

            if byName[name] == nil {
                let displayName = scDisplayNames[name]
                byName[name] = InterfaceInfo(
                    id: name,
                    displayName: displayName,
                    category: category(for: name, scDisplayName: displayName),
                    ipv4Addresses: [],
                    ipv6Addresses: [],
                    macAddress: nil,
                    linkSpeedBps: nil,
                    linkState: .unknown,
                    rxBytes: 0,
                    txBytes: 0,
                    mtu: 0,
                    flags: flags
                )
            }

            switch Int32(family) {
            case AF_INET:
                if let addr = ifa.pointee.ifa_addr {
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                        var inAddr = sin.pointee.sin_addr
                        inet_ntop(AF_INET, &inAddr, &buf, socklen_t(INET_ADDRSTRLEN))
                    }
                    let ip = String(cString: buf)
                    byName[name]?.ipv4Addresses.append(ip)
                }

            case AF_INET6:
                if let addr = ifa.pointee.ifa_addr {
                    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                        var in6Addr = sin6.pointee.sin6_addr
                        inet_ntop(AF_INET6, &in6Addr, &buf, socklen_t(INET6_ADDRSTRLEN))
                    }
                    let ip = String(cString: buf)
                    // Skip link-local unless it's the only address
                    byName[name]?.ipv6Addresses.append(ip)
                }

            case AF_LINK:
                if let addr = ifa.pointee.ifa_addr {
                    addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { sdl in
                        let mac = macString(from: sdl)
                        if !mac.isEmpty { byName[name]?.macAddress = mac }
                    }
                }

            default:
                break
            }

            ptr = ifa.pointee.ifa_next
        }

        // Enrich with sysctl stats
        enrichWithSysctl(interfaces: &byName)

        // Wi-Fi: the sysctl `ifi_baudrate` field badly under-reports modern PHY
        // rates (it's a stale/legacy value), so a Wi-Fi 6 link can read as a few
        // Mbps. CoreWLAN exposes the actual negotiated transmit rate (in Mbps),
        // which is the meaningful "link speed" for a wireless interface.
        if let wifiBSD = byName.values.first(where: { $0.category == .wifi })?.id,
           let wifi = CWWiFiClient.shared().interface(withName: wifiBSD) ?? CWWiFiClient.shared().interface() {
            let mbps = wifi.transmitRate()   // megabits/sec, 0 when disconnected
            if mbps > 0 { byName[wifiBSD]?.linkSpeedBps = UInt64(mbps * 1_000_000) }
        }

        return byName.values.sorted { $0.id < $1.id }
    }

    // MARK: - sysctl enrichment (link state, speed, rx/tx bytes)

    private static func enrichWithSysctl(interfaces: inout [String: InterfaceInfo]) {
        // NET_RT_IFLIST2 yields if_msghdr2 / if_data64 — 64-bit rx/tx byte counters
        // (the 32-bit if_data counters wrap every 4 GiB and would under-report the
        // on-wire throughput during fast transfers) and a 64-bit baudrate (the 32-bit
        // one caps link speed at ~4.3 Gbps). Same source netstat -b uses.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0 else { return }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return }

        var offset = 0
        while offset < len {
            let remaining = len - offset
            guard remaining >= MemoryLayout<if_msghdr>.size else { break }

            let msglen: Int = buf.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self).ifm_msglen.asInt
            }
            guard msglen > 0, msglen <= remaining else { break }

            let msgtype: UInt8 = buf.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self).ifm_type
            }

            if msgtype == UInt8(RTM_IFINFO2) {
                guard remaining >= MemoryLayout<if_msghdr2>.size else { offset += msglen; continue }
                let hdr: if_msghdr2 = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self) }
                let data = hdr.ifm_data   // if_data64: 64-bit ibytes/obytes/baudrate

                // Get interface name from the sockaddr_dl that follows the header
                let sdlOffset = offset + MemoryLayout<if_msghdr2>.size
                if sdlOffset + MemoryLayout<sockaddr_dl>.size <= len {
                    let sdl: sockaddr_dl = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: sdlOffset, as: sockaddr_dl.self) }
                    let nameLen = Int(sdl.sdl_nlen)
                    if nameLen > 0 {
                        let nameStart = sdlOffset + MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)!
                        let nameBytes = buf[nameStart ..< nameStart + nameLen]
                        let name = String(bytes: nameBytes, encoding: .ascii) ?? ""

                        if !name.isEmpty {
                            interfaces[name]?.rxBytes = UInt64(data.ifi_ibytes)
                            interfaces[name]?.txBytes = UInt64(data.ifi_obytes)
                            interfaces[name]?.mtu = Int(data.ifi_mtu)
                            let baud = UInt64(data.ifi_baudrate)
                            interfaces[name]?.linkSpeedBps = baud > 0 ? baud : nil

                            // Infer link state from IFF_RUNNING (0x40) in ifm_flags
                            let ifFlags = hdr.ifm_flags
                            let isRunning = ifFlags & 0x40 != 0
                            let isUp = ifFlags & 0x1 != 0
                            interfaces[name]?.linkState = (isUp && isRunning) ? .up : (isUp ? .unknown : .down)
                        }
                    }
                }
            }

            offset += msglen
        }
    }

    // MARK: - Routing table via sysctl NET_RT_DUMP

    static func gatherRoutes() -> [RouteEntry] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return [] }

        var routes: [RouteEntry] = []
        var offset = 0

        while offset < len {
            let remaining = len - offset
            guard remaining >= MemoryLayout<rt_msghdr>.size else { break }

            let msglen: Int = buf.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self).rtm_msglen.asInt
            }
            guard msglen >= MemoryLayout<rt_msghdr>.size, msglen <= remaining else { break }

            let hdr: rt_msghdr = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self) }
            let addrs = Int(hdr.rtm_addrs)

            var addrOffset = offset + MemoryLayout<rt_msghdr>.size
            var destination = ""
            var gateway = ""
            var netmask = ""
            var ifaceName = ""

            // RTA_DST=1, RTA_GATEWAY=2, RTA_NETMASK=4, RTA_IFP=16, RTA_IFA=32
            for bit in [1, 2, 4, 8, 16, 32, 64, 128] {
                guard addrs & bit != 0 else { continue }
                guard addrOffset + MemoryLayout<sockaddr>.size <= offset + msglen else { break }

                let sa: sockaddr = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: addrOffset, as: sockaddr.self) }
                let saLen = max(Int(sa.sa_len), 4)

                switch bit {
                case 1: // RTA_DST
                    destination = sockaddrToString(buf: buf, offset: addrOffset, family: sa.sa_family)
                case 2: // RTA_GATEWAY
                    gateway = sockaddrToString(buf: buf, offset: addrOffset, family: sa.sa_family)
                case 4: // RTA_NETMASK
                    netmask = sockaddrToString(buf: buf, offset: addrOffset, family: sa.sa_family)
                case 16: // RTA_IFP
                    if sa.sa_family == UInt8(AF_LINK) {
                        let sdl: sockaddr_dl = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: addrOffset, as: sockaddr_dl.self) }
                        let nlen = Int(sdl.sdl_nlen)
                        if nlen > 0 {
                            let nameStart = addrOffset + MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)!
                            if nameStart + nlen <= offset + msglen {
                                let nameBytes = buf[nameStart ..< nameStart + nlen]
                                ifaceName = String(bytes: nameBytes, encoding: .ascii) ?? ""
                            }
                        }
                    }
                default: break
                }

                addrOffset += (saLen + 3) & ~3  // round up to 4-byte alignment
            }

            let flags = hdr.rtm_flags
            let isDefault = destination == "0.0.0.0" || destination.isEmpty
            var flagStr = ""
            if flags & Int32(RTF_UP) != 0      { flagStr += "U" }
            if flags & Int32(RTF_GATEWAY) != 0 { flagStr += "G" }
            if flags & Int32(RTF_HOST) != 0    { flagStr += "H" }
            if flags & Int32(RTF_STATIC) != 0  { flagStr += "S" }

            // RTA_IFP isn't always present; fall back to if_indextoname(rtm_index)
            if ifaceName.isEmpty && hdr.rtm_index > 0 {
                var buf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                if if_indextoname(UInt32(hdr.rtm_index), &buf) != nil {
                    ifaceName = String(cString: buf)
                }
            }

            if !destination.isEmpty || !gateway.isEmpty {
                routes.append(RouteEntry(
                    destination: destination.isEmpty ? "default" : destination,
                    gateway: gateway,
                    netmask: netmask.isEmpty ? nil : netmask,
                    interfaceName: ifaceName,
                    isDefault: isDefault,
                    flags: flagStr
                ))
            }

            offset += msglen
        }

        return routes.sorted { $0.isDefault && !$1.isDefault }
    }

    // MARK: - SystemConfiguration display name lookup

    static func buildSCDisplayNames() -> [String: String] {
        var names: [String: String] = [:]
        guard let scIfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return names }
        for iface in scIfaces {
            if let bsd = SCNetworkInterfaceGetBSDName(iface) as String?,
               let display = SCNetworkInterfaceGetLocalizedDisplayName(iface) as String? {
                names[bsd] = display
            }
        }
        return names
    }

    // MARK: - Helpers

    // Uses SystemConfiguration display name when available to distinguish
    // real ethernet/Wi-Fi from Thunderbolt bridge pseudo-ports and AWDL.
    static func category(for name: String, scDisplayName: String? = nil) -> InterfaceCategory {
        // SC gives us ground truth for en* interfaces
        if let display = scDisplayName?.lowercased() {
            if display.contains("wi-fi") || display.contains("airport")  { return .wifi }
            // "Thunderbolt Bridge" → bridge wins over thunderbolt; check bridge first
            if display.contains("bridge")                                { return .bridge }
            if display.contains("thunderbolt")                           { return .thunderbolt }
            if display.contains("ethernet") || display.contains("lan")  { return .ethernet }
        }
        switch true {
        case name.hasPrefix("lo"):      return .loopback
        case name.hasPrefix("en"):      return .ethernet   // fallback if SC unavailable
        case name.hasPrefix("bridge"):  return .bridge
        case name.hasPrefix("vlan"):    return .vlan
        case name.hasPrefix("utun"):    return .tunnel
        case name.hasPrefix("ipsec"):   return .tunnel
        case name.hasPrefix("gif"):     return .tunnel
        case name.hasPrefix("stf"):     return .tunnel
        case name.hasPrefix("pdp_ip"):  return .cellular
        case name.hasPrefix("awdl"):    return .awdl
        case name.hasPrefix("llw"):     return .awdl
        case name.hasPrefix("ap"):      return .awdl       // Wi-Fi AP mode
        case name.hasPrefix("anpi"):    return .other      // Apple NCM private interface
        default:                        return .other
        }
    }

    private static func macString(from sdl: UnsafePointer<sockaddr_dl>) -> String {
        let nlen = Int(sdl.pointee.sdl_nlen)
        let alen = Int(sdl.pointee.sdl_alen)
        guard alen == 6 else { return "" }

        // sdl_data is a variable-length field; Swift bridges it as a small fixed tuple,
        // so subscripting it directly crashes when nlen > tuple size. Use raw pointer
        // arithmetic to reach sdl_data[nlen] where the MAC bytes actually live.
        let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)!
        let macBase = UnsafeRawPointer(sdl) + dataOffset + nlen
        let bytes = (0..<6).map { macBase.load(fromByteOffset: $0, as: UInt8.self) }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    // MARK: - Port topology (Thunderbolt + USB device tree)

    /// Queries the system for physical port occupancy, entirely in-process via
    /// IOKit + CoreGraphics (no `ioreg` / `system_profiler` subprocess), so it works
    /// in both the Developer-ID and sandboxed App Store builds:
    /// - Which TB/USB4 receptacles have a Thunderbolt device connected
    /// - Which receptacle a USB-connected iPhone/iPad is plugged into
    /// - The USB device tree (hubs, peripherals, network adapters)
    /// - USB-C power state, and external displays
    ///
    /// `displayNames` (CGDirectDisplayID → NSScreen name) and `bluetooth` (connected
    /// devices) are gathered on the main actor by the caller and passed in, since
    /// NSScreen and IOBluetooth's classic API are main-thread-affine.
    nonisolated static func queryPortStatus(displayNames: [UInt32: String],
                                            bluetooth: [BluetoothProbe.RawBT] = []) -> PortStatus {
        var status = PortStatus()

        // Build the IOService-plane registry tree ONCE (equivalent to `ioreg -a -l`);
        // both the Thunderbolt and USB passes read from it.
        let tree = IOKitProbe.serviceTree()

        // Thunderbolt: USB4 bus → physical receptacle, and which receptacles have a
        // TB device connected.
        let tb = thunderbolt(tree: tree)
        status.tbConnected = tb.tbConnected

        // USB device tree: BSD-name → receptacle, classified peripherals (with hub
        // nesting), and a USB-tethered iPhone/iPad's bus.
        let scan = usbScan(tree: tree, busToReceptacle: tb.busToReceptacle)
        status.deviceReceptacle = scan.bsd
        if let bus = scan.phoneBus {
            let recep = tb.busToReceptacle[bus]
            status.phoneReceptacle = recep
            status.phoneDeviceKind = scan.phoneKind
            if let r = recep { status.usbDeviceName[r] = scan.phoneKind }
        }

        // Physical attachment + power state per port, from the USB-C PD controller.
        let hpm = IOKitProbe.usbCPower()
        status.hpmConnected = hpm.connected
        status.hpmPower = hpm.power

        // External displays (CoreGraphics) grouped under the synthetic "Displays"
        // entity (receptacle -2): macOS exposes no port mapping for them.
        status.attachedDevices = scan.devices
            + buildDisplays(IOKitProbe.externalDisplays(), names: displayNames)
            + buildBluetooth(bluetooth, battery: IOKitProbe.bluetoothHIDBattery(),
                             hidUsage: IOKitProbe.hidGenericDesktopUsage())

        // System AC/charging state (AppleSmartBattery) — system-level, not per-port.
        if let p = IOKitProbe.systemPower() {
            status.systemPower = SystemPower(onAC: p.onAC, charging: p.charging,
                fullyCharged: p.fullyCharged, level: p.level, watts: p.watts,
                adapterName: p.adapterName)
        }

        return status
    }

    /// Extracts the Thunderbolt/USB4 topology from the registry tree. Each Depth-0
    /// host switch is one bus (its `Router ID`) and one physical receptacle
    /// (id = bus + 1, matching the receptacle numbering `system_profiler` reports);
    /// a Depth≥1 switch beneath a host means that receptacle has a TB device.
    nonisolated private static func thunderbolt(tree: [String: Any]) -> (busToReceptacle: [Int: Int], tbConnected: [Int: Bool]) {
        var busToReceptacle: [Int: Int] = [:]
        var tbConnected: [Int: Bool] = [:]
        func walk(_ node: [String: Any], _ hostBus: Int?) {
            var host = hostBus
            if (node["IOObjectClass"] as? String)?.contains("IOThunderboltSwitch") == true,
               let depth = (node["Depth"] as? NSNumber)?.intValue {
                if depth == 0, let rid = (node["Router ID"] as? NSNumber)?.intValue {
                    host = rid
                    busToReceptacle[rid] = rid + 1
                    if tbConnected[rid + 1] == nil { tbConnected[rid + 1] = false }
                } else if depth >= 1, let h = host {
                    tbConnected[h + 1] = true
                }
            }
            for child in (node["IORegistryEntryChildren"] as? [[String: Any]]) ?? [] {
                walk(child, host)
            }
        }
        walk(tree, nil)
        return (busToReceptacle, tbConnected)
    }

    /// Builds Display device chips (receptacle -2) from CoreGraphics displays, using
    /// NSScreen names (passed from the main actor) and decoding the EDID vendor when
    /// CoreGraphics surfaces a valid packed-PnP id.
    nonisolated private static func buildDisplays(_ raws: [IOKitProbe.RawDisplay], names: [UInt32: String]) -> [AttachedDevice] {
        raws.map { d in
            let vendor = pnpVendorName(d.vendor)
            let name = names[d.id] ?? vendor.map { "\($0) Display" } ?? "External Display"
            let detail: String?
            if d.width > 0 && d.height > 0 {
                detail = d.refreshHz > 0 ? "\(d.width) × \(d.height) @ \(Int(d.refreshHz.rounded())) Hz"
                                         : "\(d.width) × \(d.height)"
            } else { detail = nil }
            return AttachedDevice(id: "disp-\(d.id)", name: name, receptacle: -2, kind: .display,
                                  vendorName: vendor, detail: detail, connection: "Display")
        }
    }

    /// Builds connected-Bluetooth device chips (receptacle -4) from the IOBluetooth
    /// list, merging in HID battery % from the IORegistry by address. Audio devices
    /// won't have a battery (macOS exposes it only via the Bluetooth daemon).
    nonisolated private static func buildBluetooth(_ raws: [BluetoothProbe.RawBT],
                                                   battery: [String: Int],
                                                   hidUsage: [String: Int]) -> [AttachedDevice] {
        raws.compactMap { d in
            // The address is the stable identity and the battery-merge key; an
            // address-less device can't be uniquely identified, so skip it.
            guard !d.address.isEmpty else { return nil }
            // HID usage is authoritative for input devices and is the ONLY reliable
            // signal for BLE mice/keyboards (no Class-of-Device); fall back to CoD + name.
            let kind = hidUsage[d.name].flatMap(USBDeviceKind.classifyHIDUsage)
                ?? USBDeviceKind.classifyBluetooth(major: d.major, minor: d.minor, name: d.name)
            let pct  = battery[normalizeBTAddress(d.address)]
            return AttachedDevice(id: "bt-\(d.address)", name: d.name, receptacle: -4, kind: kind,
                                  serial: d.address, connection: "Bluetooth", batteryPercent: pct)
        }
    }

    /// Decodes `CGDisplayVendorNumber` into a maker name when it carries a valid
    /// 3-letter EDID PnP id (CoreGraphics often returns 0/garbage, so validate first).
    nonisolated private static func pnpVendorName(_ vendor: UInt32) -> String? {
        guard vendor > 0, vendor <= 0xFFFF else { return nil }
        let v = UInt16(vendor)
        func validLetter(_ shift: UInt16) -> Bool {
            let code = Int((v >> shift) & 0x1F)   // 1→'A' … 26→'Z'
            return code >= 1 && code <= 26
        }
        guard validLetter(10), validLetter(5), validLetter(0) else { return nil }
        return edidVendorName(String(v, radix: 16))
    }

    /// Dev-only: prints the in-process probe results so they can be diffed against
    /// `ioreg` / `system_profiler`. Invoked via the `--probe-dump` launch flag.
    static func probeDump() {
        let names = IOKitProbe.displayNames()
        let s = queryPortStatus(displayNames: names)
        print("=== Thunderbolt ===")
        print("tbConnected:", s.tbConnected.sorted { $0.key < $1.key })
        print("=== USB-C power (AppleHPM) ===")
        print("connected:", s.hpmConnected.sorted { $0.key < $1.key })
        print("power:    ", s.hpmPower.sorted { $0.key < $1.key })
        print("=== System power (AppleSmartBattery — system-level, NOT per-port) ===")
        print("systemPower:", s.systemPower as Any, " label:", s.systemPower?.label as Any)
        print("=== iPhone/iPad ===")
        print("phoneReceptacle:", s.phoneReceptacle as Any, " kind:", s.phoneDeviceKind)
        print("=== BSD → receptacle ===")
        print(s.deviceReceptacle.sorted { $0.key < $1.key })
        print("=== Devices (\(s.attachedDevices.count)) ===")
        for d in s.attachedDevices.sorted(by: { $0.receptacle < $1.receptacle }) {
            print("  recep=\(d.receptacle) [\(d.kind)] \(d.name)"
                + " | maker=\(d.vendorName ?? "-")"
                + " | \(d.connectionLabel) | \(d.speedLabel) | \(d.classLabel) | \(d.idLabel)"
                + (d.parentID.map { " | parent=\($0)" } ?? "")
                + (d.interfaceBSD.map { " | bsd=\($0)" } ?? "")
                + (d.detail.map { " | \($0)" } ?? ""))
        }
    }

    struct USBScan {
        var bsd: [String: Int] = [:]
        var devices: [AttachedDevice] = []
        var phoneBus: Int?
        var phoneKind: String = "iPhone"
    }

    /// Walks the in-process registry tree (built by IOKitProbe.serviceTree, which
    /// mirrors `ioreg -a -l`) where BSD names live, correlating each USB device's
    /// locationID bus with the TB receptacle map. A locationID is only inherited
    /// from an actual USB device node (one with a USB product name) so built-in
    /// interfaces aren't mis-mapped. Returns network-interface BSD names per
    /// receptacle, classified peripherals (with hub nesting), and a tethered phone.
    nonisolated private static func usbScan(tree: [String: Any], busToReceptacle: [Int: Int]) -> USBScan {
        var scan = USBScan()
        var locToBSD = [String: String]()   // device locationID hex → its network BSD name
        func walk(_ node: [String: Any], _ usbLoc: Int?, _ parentUSBId: String?) {
            var loc = usbLoc
            var childParent = parentUSBId   // USB device id inherited by the subtree

            // A USB device node carries a product name + locationID. It (re)sets
            // the inherited USB location for its whole subtree, and becomes the
            // parent (hub/dock) of any USB devices nested beneath it.
            if let name = node["USB Product Name"] as? String,
               let l = node["locationID"] as? NSNumber {
                loc = l.intValue
                let bus = (l.intValue >> 24) & 0xFF
                let idHex = String(l.intValue, radix: 16)
                let lname = name.lowercased()
                let isPad = lname.contains("ipad")
                let isPhone = lname.contains("iphone") || isPad
                if isPhone {
                    // A USB-tethered iPhone/iPad: record its bus (a locked one is
                    // hidden from system_profiler, but is in the IOKit registry).
                    scan.phoneBus = bus
                    scan.phoneKind = isPad ? "iPad" : "iPhone"
                } else if let recep = busToReceptacle[bus] {
                    let cls = (node["bDeviceClass"] as? NSNumber)?.intValue ?? 0
                    scan.devices.append(AttachedDevice(
                        id: idHex,
                        name: name,
                        receptacle: recep,
                        kind: USBDeviceKind.classify(name: name, classCode: cls),
                        parentID: parentUSBId,
                        vendorName: (node["USB Vendor Name"] as? String) ?? (node["kUSBVendorString"] as? String),
                        vendorID: (node["idVendor"] as? NSNumber)?.intValue,
                        productID: (node["idProduct"] as? NSNumber)?.intValue,
                        serial: (node["USB Serial Number"] as? String) ?? (node["kUSBSerialNumberString"] as? String),
                        classCode: cls,
                        usbVersion: usbVersionString((node["bcdUSB"] as? NSNumber)?.intValue),
                        linkSpeedBps: (node["UsbLinkSpeed"] as? NSNumber)?.uint64Value,
                        connection: "USB"))
                }
                if !isPhone { childParent = idHex }
            }

            // A BSD name under a USB device maps to that device's receptacle.
            if let bsd = node["BSD Name"] as? String, let loc {
                let bus = (loc >> 24) & 0xFF
                let hex = String(loc, radix: 16)
                if let recep = busToReceptacle[bus] {
                    scan.bsd[bsd] = recep
                    if locToBSD[hex] == nil { locToBSD[hex] = bsd }
                }
            }

            if let kids = node["IORegistryEntryChildren"] as? [[String: Any]] {
                for k in kids { walk(k, loc, childParent) }
            }
        }
        walk(tree, nil, nil)

        // De-duplicate composite devices (they appear under several USB nodes),
        // and tag network devices with the interface they provide + a network kind.
        var seen = Set<String>()
        scan.devices = scan.devices.compactMap { d in
            guard !seen.contains(d.id) else { return nil }
            seen.insert(d.id)
            var d = d
            if let bsd = locToBSD[d.id] { d.interfaceBSD = bsd; d.kind = .network }
            return d
        }
        return scan
    }

    // MARK: - Hardware port construction

    static func buildHardwarePorts(from interfaces: [InterfaceInfo],
                                   macModel: String,
                                   portStatus: PortStatus = PortStatus()) -> [HardwarePort] {
        var ports: [HardwarePort] = []
        let layout = hardwarePortLayout(model: macModel)

        // Thunderbolt virtual en* interfaces grouped by port number
        var byPort: [Int: [String]] = [:]
        for iface in interfaces where iface.thunderboltPortNumber != nil {
            byPort[iface.thunderboltPortNumber!, default: []].append(iface.id)
        }
        // Do we have authoritative port-status data? If both probes came back
        // empty the queries failed — only then fall back to the link heuristic.
        let haveData = !portStatus.tbConnected.isEmpty || !portStatus.hpmConnected.isEmpty

        // USB network devices (MiFi, Ethernet dongle) are rendered as device chips
        // with their interface anchored beneath them (handled in the graph), so they
        // are NOT folded into the port here.
        let deviceReceptacles = Set(portStatus.attachedDevices.map { $0.receptacle })

        for port in byPort.keys.sorted() {
            let info = layout[port]
            let tbMembers = (byPort[port] ?? []).sorted()
            // Light the port if ANY physical attachment exists: a Thunderbolt
            // device, a USB-C cable/device/charger (AppleHPM), or an attached device.
            let lit: Bool
            if haveData {
                lit = (portStatus.tbConnected[port] ?? false)
                    || (portStatus.hpmConnected[port] ?? false)
                    || (portStatus.phoneReceptacle == port)
                    || deviceReceptacles.contains(port)
            } else {
                lit = tbMembers.compactMap { n in interfaces.first { $0.id == n } }
                              .contains { $0.hasLink }
            }
            ports.append(HardwarePort(
                id: port,
                side: info?.side ?? "",
                position: info?.position ?? "",
                childBSDNames: tbMembers,
                hasConnectedDevice: lit,
                hasPower: portStatus.hpmPower[port] ?? false
            ))
        }

        // iPhone / iPad USB — map to the physical receptacle ioreg reports it on.
        let phoneIfaces = interfaces.filter { $0.isPhoneAssociated && $0.thunderboltPortNumber == nil }
        if !phoneIfaces.isEmpty {
            let info = portStatus.phoneReceptacle.flatMap { layout[$0] }
            // How is the phone tethered? USB shows up in the IOUSB tree (a
            // receptacle); a Wi-Fi hotspot lands a 172.20.10.x address on the
            // Wi-Fi interface; Bluetooth PAN shows a "Bluetooth" display name.
            let medium: String
            if portStatus.phoneReceptacle != nil {
                medium = "USB-C"
            } else if phoneIfaces.contains(where: { $0.category == .wifi }) {
                medium = "Wi-Fi"
            } else if phoneIfaces.contains(where: { ($0.displayName ?? "").lowercased().contains("bluetooth") }) {
                medium = "Bluetooth"
            } else {
                medium = "USB-C"
            }
            ports.append(HardwarePort(
                id: 0,
                side: info?.side ?? "",
                position: info?.position ?? "",
                childBSDNames: phoneIfaces.map(\.id).sorted(),
                hasConnectedDevice: true,
                isPhone: true,
                deviceName: portStatus.phoneDeviceKind,
                physicalReceptacle: portStatus.phoneReceptacle,
                connectionMedium: medium
            ))
        }

        return ports
    }

    // MARK: - Egress (uplink) detection

    /// Determines the physical last hop to the internet and its network identity.
    static func computeEgress(routes: [RouteEntry], interfaces: [InterfaceInfo]) -> EgressInfo? {
        // The physical default route (not a tunnel) is the real egress.
        guard let r = routes.first(where: {
            $0.isDefault && !$0.interfaceName.isEmpty
            && !$0.interfaceName.hasPrefix("utun") && !$0.interfaceName.hasPrefix("ipsec")
        }) else { return nil }

        let ifname = r.interfaceName
        let iface  = interfaces.first { $0.id == ifname }
        let kind: EgressInfo.Kind
        switch iface?.category {
        case .wifi:                   kind = .wifi
        case .cellular:               kind = .cellular
        case .ethernet, .thunderbolt: kind = .wired
        default:                      kind = .other
        }

        // Only the Wi-Fi SSID is a trustworthy network identity. (DNS search
        // domains were misleading — corporate domains persist even off-VPN.)
        let name: String? = (kind == .wifi) ? currentSSID() : nil
        return EgressInfo(viaInterface: ifname, kind: kind, name: name)
    }

    /// Current Wi-Fi SSID, or nil if unavailable (needs Location authorization on
    /// recent macOS; a non-bundled `swift run` binary often returns nil).
    static func currentSSID() -> String? {
        guard let ssid = CWWiFiClient.shared().interface()?.ssid(), !ssid.isEmpty else { return nil }
        return ssid
    }


    // MARK: - Gateway node construction

    static func buildGatewayNodes(from routes: [RouteEntry], interfaces: [InterfaceInfo]) -> [GatewayNode] {
        // Collect all IPs assigned to local interfaces so we don't re-show them as gateways
        let localIPs = Set(interfaces.flatMap { $0.ipv4Addresses })

        var byIP: [String: GatewayNode] = [:]
        // Names of tunnel/VPN interfaces, so we can flag VPN gateways.
        let tunnelIfaces = Set(interfaces.filter { $0.category == .tunnel }.map { $0.id })

        for route in routes {
            let gw = route.gateway
            // Skip empty, loopback, and non-IPv4 (link-local IPv6, etc.)
            guard !gw.isEmpty, gw != "0.0.0.0", gw != "127.0.0.1" else { continue }
            guard gw.contains(".") else { continue }
            // Normally skip gateways that are one of our own interface IPs — BUT a
            // point-to-point VPN tunnel lists its own local address as the default
            // gateway, and that genuinely IS the VPN's egress. Keep those.
            if localIPs.contains(gw) && !route.isDefault { continue }

            if byIP[gw] == nil {
                byIP[gw] = GatewayNode(id: gw, isDefault: false, reachableVia: [])
            }
            if route.isDefault { byIP[gw]?.isDefault = true }
            if tunnelIfaces.contains(route.interfaceName) { byIP[gw]?.isVPN = true }
            if !route.interfaceName.isEmpty,
               !(byIP[gw]?.reachableVia.contains(route.interfaceName) ?? false) {
                byIP[gw]?.reachableVia.append(route.interfaceName)
            }
        }
        // Order each gateway's interfaces by the macOS network SERVICE ORDER (the
        // System Settings drag-list — macOS's actual source of truth, since it
        // exposes no numeric route metric), so a gateway shared by several uplinks
        // anchors to whichever the OS prefers.
        let rank = serviceOrder()
        for (ip, var node) in byIP {
            node.reachableVia.sort { (rank[$0] ?? Int.max) < (rank[$1] ?? Int.max) }
            byIP[ip] = node
        }

        // Precedence among DEFAULT gateways: VPN tunnels (which capture 0.0.0.0/0)
        // first, then physical defaults ranked by their best interface's service
        // order. So GW #1 is the active uplink and the VPN egresses through it.
        func bestRank(_ id: String) -> Int {
            (byIP[id]?.reachableVia.compactMap { rank[$0] }.min()) ?? Int.max
        }
        let vpnDefaults  = byIP.values.filter { $0.isDefault &&  $0.isVPN }.map(\.id).sorted()
        let physDefaults = byIP.values.filter { $0.isDefault && !$0.isVPN }.map(\.id)
            .sorted { bestRank($0) != bestRank($1) ? bestRank($0) < bestRank($1) : $0 < $1 }
        for (i, ip) in (vpnDefaults + physDefaults).enumerated() { byIP[ip]?.precedence = i + 1 }

        // Sort: by precedence (winning default first), then non-defaults by IP.
        return Array(byIP.values).sorted {
            switch ($0.precedence, $1.precedence) {
            case let (a?, b?): return a < b
            case (_?, nil):    return true
            case (nil, _?):    return false
            default:           return $0.id < $1.id
            }
        }
    }

    /// The OS primary network interface (its default gateway is the active one).
    static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "NetLights" as CFString, nil, nil),
              let info = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return info["PrimaryInterface"] as? String
    }

    /// Interface (BSD name) → its rank in the macOS network service order
    /// (0 = highest priority). Mirrors System Settings ▸ Network ▸ Set Service Order.
    static func serviceOrder() -> [String: Int] {
        guard let store = SCDynamicStoreCreate(nil, "NetLights" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "Setup:/Network/Global/IPv4" as CFString) as? [String: Any],
              let order = global["ServiceOrder"] as? [String] else { return [:] }
        var rank: [String: Int] = [:]
        for (i, serviceID) in order.enumerated() {
            let key = "Setup:/Network/Service/\(serviceID)/Interface" as CFString
            if let svc = SCDynamicStoreCopyValue(store, key) as? [String: Any],
               let dev = svc["DeviceName"] as? String, rank[dev] == nil {
                rank[dev] = i
            }
        }
        return rank
    }

    private static func sockaddrToString(buf: [UInt8], offset: Int, family: UInt8) -> String {
        switch Int32(family) {
        case AF_INET:
            let sin: sockaddr_in = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: sockaddr_in.self) }
            var addr = sin.sin_addr
            var result = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &result, socklen_t(INET_ADDRSTRLEN))
            return String(cString: result)
        case AF_INET6:
            let sin6: sockaddr_in6 = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: sockaddr_in6.self) }
            var addr = sin6.sin6_addr
            var result = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &addr, &result, socklen_t(INET6_ADDRSTRLEN))
            return String(cString: result)
        default:
            return ""
        }
    }
}

// MARK: - Helpers for awkward integer widths in C structs

private extension UInt16 {
    var asInt: Int { Int(self) }
}

// MARK: - Device-attribute formatting

/// `bcdUSB` (BCD, e.g. 0x0210) → "USB 2.1".
func usbVersionString(_ bcd: Int?) -> String? {
    guard let b = bcd, b > 0 else { return nil }
    let major = (b >> 8) & 0xFF
    let minor = (b >> 4) & 0x0F
    return "USB \(major).\(minor)"
}

/// Decodes a display's EDID vendor id (3 packed 5-bit letters, e.g. "1e6d") into
/// its PnP manufacturer code (e.g. "GSM" = LG), mapping common ones to a name.
func edidVendorName(_ hex: String) -> String? {
    guard let v = UInt16(hex, radix: 16), v != 0 else { return nil }
    func letter(_ shift: Int) -> Character? {
        let code = Int((v >> UInt16(shift)) & 0x1F)
        guard let scalar = UnicodeScalar(code + 64) else { return nil }   // 1→'A'
        return Character(scalar)
    }
    guard let c1 = letter(10), let c2 = letter(5), let c3 = letter(0) else { return nil }
    let pnp = String([c1, c2, c3])
    let known = ["GSM": "LG", "BNQ": "BenQ", "DEL": "Dell", "APP": "Apple",
                 "SAM": "Samsung", "ACR": "Acer", "AUS": "ASUS", "HWP": "HP",
                 "LEN": "Lenovo", "PHL": "Philips", "VSC": "ViewSonic",
                 "GGL": "Google", "SNY": "Sony", "MSI": "MSI", "AOC": "AOC",
                 "NEC": "NEC", "EIZ": "EIZO", "HPN": "HP"]
    return known[pnp] ?? pnp
}

import Foundation
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
    private let locationAuth = LocationAuth()

    func start() {
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
        serviceRank = Self.serviceOrder()

        // Build hardware ports immediately from the *cached* port status so the
        // UI never blocks. The actual TB/USB query (system_profiler + ioreg) is
        // slow — run it off the main thread and refresh the cache when it lands.
        hardwarePorts = Self.buildHardwarePorts(from: newInterfaces,
                                                macModel: macModel,
                                                portStatus: lastPortStatus)
        attachedDevices = lastPortStatus.attachedDevices

        // Re-query topology roughly every ~5s, and never run two at once.
        portQueryCounter += 1
        if (portQueryCounter == 1 || portQueryCounter % 7 == 0) && !portQueryInFlight {
            portQueryInFlight = true
            let model = macModel
            Task.detached(priority: .utility) {
                let status = NetworkMonitor.queryPortStatus()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.lastPortStatus = status
                    self.portQueryInFlight = false
                    // Rebuild against the freshest interface list.
                    self.hardwarePorts = NetworkMonitor.buildHardwarePorts(
                        from: self.interfaces, macModel: model, portStatus: status)
                    self.attachedDevices = status.attachedDevices
                }
            }
        }
    }

    private var portQueryCounter = 0
    private var portQueryInFlight = false
    private var lastPortStatus: PortStatus = PortStatus()

    struct PortStatus {
        /// Receptacle number → true if a *Thunderbolt* device is connected.
        var tbConnected: [Int: Bool] = [:]
        /// Receptacle number → human-readable USB device name (e.g. "iPhone").
        var usbDeviceName: [Int: String] = [:]
        /// Physical receptacle the iPhone/iPad is plugged into, if any.
        var phoneReceptacle: Int? = nil
        /// Port number → true if anything is physically attached (cable/device/power),
        /// from the USB-C PD controller (AppleHPM). Authoritative connection signal.
        var hpmConnected: [Int: Bool] = [:]
        /// Port number → true if USB-C power (a charger) is attached.
        var hpmPower: [Int: Bool] = [:]
        /// USB-attached network interface BSD name → physical receptacle id.
        var deviceReceptacle: [String: Int] = [:]
        /// Non-network USB peripherals attached to ports (audio, storage, …).
        var attachedDevices: [AttachedDevice] = []
    }

    // MARK: - Traffic LED logic

    private func updateTrafficStates(newInterfaces: [InterfaceInfo]) {
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

        return byName.values.sorted { $0.id < $1.id }
    }

    // MARK: - sysctl enrichment (link state, speed, rx/tx bytes)

    private static func enrichWithSysctl(interfaces: inout [String: InterfaceInfo]) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST, 0]
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

            if msgtype == UInt8(RTM_IFINFO) {
                let hdr: if_msghdr = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self) }
                let data = hdr.ifm_data

                // Get interface name from the sockaddr_dl that follows the header
                let sdlOffset = offset + MemoryLayout<if_msghdr>.size
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
                            // Swift binds if_data.ifi_baudrate as UInt32 (covers up to ~4.3 Gbps).
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

    /// Queries the system for physical port occupancy:
    /// - Which TB/USB4 receptacles have a *Thunderbolt* device connected
    /// - Which receptacle a USB-connected iPhone/iPad is plugged into
    ///
    /// The TB tree (`SPThunderboltDataType`) reports one `thunderboltusb4_bus_N`
    /// entry per port, each with a `receptacle_*_tag` dict giving the physical
    /// receptacle id and its connection status. An iPhone attaches as a *USB*
    /// device (not a TB device), so it never appears in the TB tree and the
    /// (locked) iPhone is also hidden from `SPUSBDataType` — but `ioreg` exposes
    /// it as `iPhone@<locationID>`, whose high byte is the USB4 bus number.
    nonisolated static func queryPortStatus() -> PortStatus {
        var status = PortStatus()
        var busToReceptacle: [Int: Int] = [:]   // USB4 bus index → physical receptacle id

        if let tbJSON = runProfiler("SPThunderboltDataType"),
           let buses = tbJSON["SPThunderboltDataType"] as? [[String: Any]] {
            for bus in buses {
                // "_name" = "thunderboltusb4_bus_2" → trailing int is the bus index.
                let name   = bus["_name"] as? String ?? ""
                let busNum = Int(name.split(separator: "_").last.map(String.init) ?? "")

                // The receptacle dict key is dynamic ("receptacle_1_tag", etc.).
                for (key, value) in bus {
                    guard key.hasPrefix("receptacle_"), key.hasSuffix("_tag"),
                          let tag = value as? [String: Any] else { continue }
                    guard let rid = Int(tag["receptacle_id_key"] as? String ?? "") else { continue }
                    let st = (tag["receptacle_status_key"] as? String ?? "").lowercased()
                    status.tbConnected[rid] = !st.contains("no_devices")
                    if let b = busNum { busToReceptacle[b] = rid }
                }
            }
        }

        // Locate a connected iPhone/iPad and map its USB4 bus → physical receptacle.
        if let bus = iPhoneUSBBus() {
            let recep = busToReceptacle[bus]
            status.phoneReceptacle = recep
            if let r = recep { status.usbDeviceName[r] = "iPhone" }
        }

        // Physical attachment + power state per port, from the USB-C PD controller.
        let hpm = queryHPMPorts()
        status.hpmConnected = hpm.connected
        status.hpmPower = hpm.power

        // Walk the USB registry once: map network interfaces → receptacle, and
        // collect non-network peripherals (audio, storage, hubs, …) as devices.
        let scan = usbScan(busToReceptacle: busToReceptacle)
        status.deviceReceptacle = scan.bsd
        status.attachedDevices  = scan.devices

        return status
    }

    struct USBScan { var bsd: [String: Int] = [:]; var devices: [AttachedDevice] = [] }

    /// Walks the IOService registry plane (where BSD names live) and correlates
    /// each USB device's locationID bus with the TB receptacle map. A locationID
    /// is only inherited from an actual USB device node (one with a USB product
    /// name) so built-in interfaces aren't mis-mapped. Returns network-interface
    /// BSD names per receptacle, plus classified peripheral devices.
    nonisolated private static func usbScan(busToReceptacle: [Int: Int]) -> USBScan {
        let task = Process()
        task.launchPath = "/usr/sbin/ioreg"
        task.arguments  = ["-a", "-l", "-w0"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        var scan = USBScan()
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let obj = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            var locToBSD = [String: String]()   // device locationID hex → its network BSD name
            func walk(_ node: [String: Any], _ usbLoc: Int?) {
                var loc = usbLoc

                // A USB device node carries a product name + locationID. It (re)sets
                // the inherited USB location for its whole subtree.
                if let name = node["USB Product Name"] as? String,
                   let l = node["locationID"] as? NSNumber {
                    loc = l.intValue
                    let bus = (l.intValue >> 24) & 0xFF
                    let lname = name.lowercased()
                    let isPhone = lname.contains("iphone") || lname.contains("ipad")
                    if let recep = busToReceptacle[bus], !isPhone {
                        let cls = (node["bDeviceClass"] as? NSNumber)?.intValue ?? 0
                        scan.devices.append(AttachedDevice(
                            id: String(l.intValue, radix: 16),
                            name: name,
                            receptacle: recep,
                            kind: USBDeviceKind.classify(name: name, classCode: cls)))
                    }
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
                    for k in kids { walk(k, loc) }
                }
            }
            if let root = obj as? [String: Any] { walk(root, nil) }
            else if let arr = obj as? [[String: Any]] { for r in arr { walk(r, nil) } }

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
        } catch { return USBScan() }
        return scan
    }

    /// Reads the USB-C Power Delivery controller (AppleHPM) to learn, per port,
    /// whether anything is physically attached and whether a charger is present.
    /// `PortNumber` here aligns with the TB receptacle id (port 3 = iPhone confirms it).
    /// A port that's active but reports no USB data device ("None") is power-only.
    nonisolated private static func queryHPMPorts() -> (connected: [Int: Bool], power: [Int: Bool]) {
        var connected: [Int: Bool] = [:]
        var power: [Int: Bool] = [:]
        let task = Process()
        task.launchPath = "/usr/sbin/ioreg"
        task.arguments  = ["-r", "-c", "AppleHPMInterfaceType10", "-a", "-d1"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let entries = try PropertyListSerialization
                .propertyList(from: data, options: [], format: nil) as? [[String: Any]] else {
                return ([:], [:])
            }
            for e in entries {
                guard let port = (e["PortNumber"] as? NSNumber)?.intValue else { continue }
                let active  = (e["ConnectionActive"] as? NSNumber)?.boolValue ?? false
                let connStr = e["IOAccessoryUSBConnectString"] as? String ?? ""
                connected[port] = active
                // Active connection with no USB data device ⇒ power-only (charger).
                power[port] = active && connStr == "None"
            }
        } catch { return ([:], [:]) }
        return (connected, power)
    }

    nonisolated private static func runProfiler(_ dataType: String) -> [String: Any]? {
        let task = Process()
        task.launchPath = "/usr/sbin/system_profiler"
        task.arguments  = [dataType, "-json"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        do {
            try task.run()
            // Drain the pipe BEFORE waiting: large output (>64 KB) overflows the
            // pipe buffer and deadlocks if we wait first.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch { return nil }
    }

    /// Returns the USB4 bus index a connected iPhone/iPad is on, parsed from the
    /// `ioreg` node name `iPhone@<locationID>`. The locationID's high byte is the
    /// bus number (e.g. 0x02100000 → bus 2). Returns nil if no device is found.
    nonisolated private static func iPhoneUSBBus() -> Int? {
        let task = Process()
        task.launchPath = "/usr/sbin/ioreg"
        task.arguments  = ["-p", "IOUSB", "-l", "-w0"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        do {
            try task.run()
            // Drain before waiting — ioreg output is ~90 KB and overflows the pipe.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let out = String(data: data, encoding: .utf8) else { return nil }
            for rawLine in out.split(separator: "\n") {
                let line = String(rawLine)
                // Match the device-tree node line: "+-o iPhone@02100000  <class ...>"
                guard line.contains("iPhone@") || line.contains("iPad@") else { continue }
                guard let at = line.range(of: "@") else { continue }
                let hex = line[at.upperBound...].prefix { $0.isHexDigit }
                if let loc = UInt32(hex, radix: 16) {
                    return Int((loc >> 24) & 0xFF)
                }
            }
        } catch { return nil }
        return nil
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

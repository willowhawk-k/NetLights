#if os(Linux)
import Foundation
import NetLightsCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// L1 interface collector — enumerate /sys/class/net and read each interface's attributes
// there (MAC, MTU, link state, speed, byte counters), plus getifaddrs for the assigned
// IPv4/IPv6 addresses + kernel flags. All read-only, no elevated privileges. Linux
// interface names differ from macOS BSD names, so the classifier is Linux-specific.

func linuxInterfaces() -> [InterfaceInfo] {
    let netDir = "/sys/class/net"
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: netDir) else { return [] }

    // getifaddrs → IPv4/IPv6 addresses + kernel flags, keyed by interface name.
    var ipv4: [String: [String]] = [:]
    var ipv6: [String: [String]] = [:]
    var flagsByName: [String: UInt32] = [:]
    var ifap: UnsafeMutablePointer<ifaddrs>?
    if getifaddrs(&ifap) == 0, let start = ifap {
        defer { freeifaddrs(start) }
        var cur: UnsafeMutablePointer<ifaddrs>? = start
        while let ifa = cur {
            let nm = String(cString: ifa.pointee.ifa_name)
            flagsByName[nm] = UInt32(ifa.pointee.ifa_flags)
            if let sa = ifa.pointee.ifa_addr {
                switch Int32(sa.pointee.sa_family) {
                case AF_INET:  if let ip = ipString(sa, AF_INET)  { ipv4[nm, default: []].append(ip) }
                case AF_INET6: if let ip = ipString(sa, AF_INET6) { ipv6[nm, default: []].append(ip) }
                default: break
                }
            }
            cur = ifa.pointee.ifa_next
        }
    }

    return names.sorted().map { name in
        let base = "\(netDir)/\(name)"
        let mac = sysRead("\(base)/address")
        let oper = sysRead("\(base)/operstate") ?? "unknown"
        let carrier = sysRead("\(base)/carrier")
        let speedMbps = Int(sysRead("\(base)/speed") ?? "")   // -1 / error for virtual & Wi-Fi
        let link: LinkState
        switch oper {
        case "up":   link = .up
        case "down": link = .down
        default:     link = carrier == "1" ? .up : (carrier == "0" ? .down : .unknown)
        }
        return InterfaceInfo(
            id: name,
            category: linuxCategory(for: name),
            ipv4Addresses: ipv4[name] ?? [],
            ipv6Addresses: ipv6[name] ?? [],
            macAddress: (mac?.isEmpty == false && mac != "00:00:00:00:00:00") ? mac : nil,
            linkSpeedBps: (speedMbps ?? -1) > 0 ? UInt64(speedMbps!) * 1_000_000 : nil,
            linkState: link,
            rxBytes: UInt64(sysRead("\(base)/statistics/rx_bytes") ?? "") ?? 0,
            txBytes: UInt64(sysRead("\(base)/statistics/tx_bytes") ?? "") ?? 0,
            mtu: Int(sysRead("\(base)/mtu") ?? "") ?? 0,
            flags: flagsByName[name] ?? 0)
    }
}

/// Linux interface name → category. Uses /sys markers (wireless, bridge) where a name
/// prefix is ambiguous, else the systemd predictable-name conventions.
func linuxCategory(for name: String) -> InterfaceCategory {
    let fm = FileManager.default
    let base = "/sys/class/net/\(name)"
    if name == "lo" { return .loopback }
    if fm.fileExists(atPath: "\(base)/wireless") || fm.fileExists(atPath: "\(base)/phy80211") { return .wifi }
    if fm.fileExists(atPath: "\(base)/bridge") { return .bridge }
    switch true {
    case name.hasPrefix("wl"):                                                 return .wifi
    case name.hasPrefix("wg"), name.hasPrefix("tun"), name.hasPrefix("tap"),
         name.hasPrefix("ppp"), name.hasPrefix("ipsec"),
         name.hasPrefix("gre"), name.hasPrefix("sit"):                         return .tunnel
    case name.hasPrefix("virbr"), name.hasPrefix("br"):                        return .bridge
    case name.contains("."):                                                   return .vlan   // eth0.100
    case name.hasPrefix("en"), name.hasPrefix("eth"), name.hasPrefix("bond"):  return .ethernet
    default:                                                                   return .other
    }
}

private func sysRead(_ path: String) -> String? {
    (try? String(contentsOfFile: path, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Render a sockaddr's IPv4/IPv6 address as a string via inet_ntop.
private func ipString(_ sa: UnsafePointer<sockaddr>, _ family: Int32) -> String? {
    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    let result: UnsafePointer<CChar>?
    if family == AF_INET {
        var a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        result = inet_ntop(AF_INET, &a, &buf, socklen_t(INET6_ADDRSTRLEN))
    } else {
        var a = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
        result = inet_ntop(AF_INET6, &a, &buf, socklen_t(INET6_ADDRSTRLEN))
    }
    return result != nil ? String(cString: buf) : nil
}
#endif

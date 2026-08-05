#if os(Linux)
import Foundation
import NetLightsCore

// L1 route collector — parse /proc/net/route (hex, little-endian) into RouteEntry values
// and derive a per-interface rank from route metrics (lower metric = higher priority),
// which feeds the shared buildGatewayNodes(rank:). Read-only, no privileges.

func linuxRoutes() -> (routes: [RouteEntry], rank: [String: Int]) {
    guard let text = try? String(contentsOfFile: "/proc/net/route", encoding: .utf8) else {
        return ([], [:])
    }
    var routes: [RouteEntry] = []
    var rank: [String: Int] = [:]   // interface → lowest default-route metric
    for line in text.split(separator: "\n").dropFirst() {   // drop the header row
        let f = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
        guard f.count >= 8,
              let dest = ipFromHexLE(f[1]),
              let gw   = ipFromHexLE(f[2]),
              let mask = ipFromHexLE(f[7]) else { continue }
        let iface = f[0]
        let flagsVal = UInt32(f[3], radix: 16) ?? 0
        let metric = Int(f[6]) ?? 0
        let isDefault = (dest == "0.0.0.0" && mask == "0.0.0.0")

        // /proc/net/route flag bits: RTF_UP=0x1, RTF_GATEWAY=0x2, RTF_HOST=0x4.
        var flags = ""
        if flagsVal & 0x1 != 0 { flags += "U" }
        if flagsVal & 0x2 != 0 { flags += "G" }
        if flagsVal & 0x4 != 0 { flags += "H" }

        routes.append(RouteEntry(
            destination: isDefault ? "default" : dest,
            gateway: gw == "0.0.0.0" ? "" : gw,
            netmask: isDefault ? nil : mask,
            interfaceName: iface,
            isDefault: isDefault,
            flags: flags,
            // The metric was parsed and thrown away before. Surfacing it is what explains
            // the "duplicate" routes a VM shows: two default routes over one interface,
            // identical in every displayed field, differ only by metric (e.g. 100 from one
            // DHCP config and 1024 from another).
            metric: metric))

        if isDefault { rank[iface] = min(rank[iface] ?? Int.max, metric) }
    }
    return (routes, rank)
}

/// Decode a /proc/net/route hex address (little-endian machine word) to dotted-quad —
/// e.g. "0140A8C0" → "192.168.64.1" (low byte first).
private func ipFromHexLE(_ hex: String) -> String? {
    guard let v = UInt32(hex, radix: 16) else { return nil }
    return "\(v & 0xff).\((v >> 8) & 0xff).\((v >> 16) & 0xff).\((v >> 24) & 0xff)"
}
#endif

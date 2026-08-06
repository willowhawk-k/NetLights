#if os(Linux)
import Foundation
import NetLightsCore

// L3 Thunderbolt collector: read /sys/bus/thunderbolt/devices and hand the raw attributes to
// the pure builder in Core. I/O only.
//
// The directory is absent entirely on a machine with no Thunderbolt controller — which is
// most PCs and every VM — and that is the ordinary case, not an error.
//
// Note `domain<N>/boot_acl` is 0600 root-only and is deliberately never read; everything
// here is world-readable and needs no privileges.

private let tbRoot = "/sys/bus/thunderbolt/devices"

private let tbAttrs = ["device_name", "vendor_name", "unique_id", "vendor", "device",
                       "authorized", "generation", "rx_speed", "tx_speed", "rx_lanes",
                       "link_speed", "link_width", "nvm_version", "uevent"]

private func readAttr(_ dir: String, _ name: String) -> String? {
    try? String(contentsOfFile: "\(dir)/\(name)", encoding: .utf8)
}

func linuxThunderboltNodes() -> [ThunderboltNode] {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: tbRoot)) ?? []).sorted()
    return names.compactMap { name in
        let kind = thunderboltEntryKind(name)
        if case .unknown = kind { return nil }
        if case .retimer = kind { return nil }          // a cable component, never a chip
        let dir = "\(tbRoot)/\(name)"

        var attrs: [String: String] = [:]
        for k in tbAttrs {
            // nvm_version can legitimately fail with -EAGAIN while the router is busy, which
            // surfaces as a read error; every attribute is optional for exactly this reason.
            if let v = readAttr(dir, k) { attrs[k] = v }
        }

        // A host router's usb4_port<N> subdirectories are the physical receptacles.
        var ports: [Int] = []
        if case .hostRouter = kind {
            for entry in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []) {
                guard entry.hasPrefix("usb4_port"), let n = Int(entry.dropFirst("usb4_port".count))
                else { continue }
                ports.append(n)
            }
            ports.sort()
        }

        return ThunderboltNode(name: name, attributes: attrs, usb4Ports: ports,
                               isXDomain: thunderboltIsXDomain(attrs["uevent"]))
    }
}

func linuxThunderbolt() -> ThunderboltTopology {
    buildThunderboltTopology(nodes: linuxThunderboltNodes())
}
#endif

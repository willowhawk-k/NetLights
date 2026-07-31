#if os(Linux)
import Foundation
import NetLightsCore

/// L1 Linux collector: interfaces (/sys/class/net + getifaddrs), routes (/proc/net/route),
/// and — reusing the SHARED portable transforms — gateways + egress. USB/Thunderbolt,
/// displays/EDID, Wi-Fi SSID, Bluetooth, power, and DNS land in later slices. All reads
/// are read-only and need no elevated privileges.
struct LinuxCollector {
    func snapshot() -> TopologySnapshot {
        let interfaces = linuxInterfaces()
        let (routes, rank) = linuxRoutes()
        let gateways = resolveVPNPaths(
            buildGatewayNodes(from: routes, interfaces: interfaces, rank: rank),
            routes: routes)
        let egress = computeEgress(routes: routes, interfaces: interfaces)
        return TopologySnapshot(
            machineModel: Self.machineModel(),
            interfaces: interfaces,
            routes: routes,
            gateways: gateways,
            egress: egress)
    }

    /// DMI product name (e.g. "MacBookPro18,3", "20XW…"); "Linux" when unreadable.
    private static func machineModel() -> String {
        let name = (try? String(contentsOfFile: "/sys/devices/virtual/dmi/id/product_name", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty == false) ? name! : "Linux"
    }
}
#endif

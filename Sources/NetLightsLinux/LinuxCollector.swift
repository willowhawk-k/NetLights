#if os(Linux)
import Foundation
import NetLightsCore

/// The Linux collector. L1 gave interfaces, routes, gateways and DNS; L3 adds the USB device
/// tree, external displays (with the monitor's real name from its EDID) and system power, so
/// the Hardware band has something to show.
///
/// Every source is read-only sysfs/procfs and needs no privileges, and every collector
/// degrades to absent rather than failing: no /sys/bus/usb, no /sys/class/drm, no
/// /sys/class/power_supply and no `iw` binary each just remove their contribution.
///
/// Still to come: Thunderbolt (/sys/bus/thunderbolt/devices) and Bluetooth (BlueZ over
/// D-Bus, which is the one source that can't be a plain file read).
struct LinuxCollector {
    func snapshot() -> TopologySnapshot {
        var interfaces = linuxInterfaces()
        let (routes, rank) = linuxRoutes()
        var gateways = resolveVPNPaths(
            buildGatewayNodes(from: routes, interfaces: interfaces, rank: rank),
            routes: routes)
        var egress = computeEgress(routes: routes, interfaces: interfaces)

        let usb = linuxUSBTopology()
        // Receptacle ids are disjoint by construction: USB uses kernel bus numbers (1, 2, …),
        // Thunderbolt starts at thunderboltPortIDBase, and the synthetic entities use the
        // negative sentinels. So the two port sets can simply be concatenated.
        let tb = linuxThunderbolt()

        // Wi-Fi: the SSID and the negotiated rate both come from nl80211, which only `iw`
        // (or NetworkManager) exposes — sysfs `speed` is meaningless for wireless. The fold
        // itself lives in Core because the model's fields are internal to that module.
        if let wifi = wifiEgressInterface(egress, interfaces: interfaces) {
            let link = linuxWiFiLink(wifi)
            applyWirelessLink(iface: wifi, ssid: link.ssid, bitrateBps: link.bitrateBps,
                              interfaces: &interfaces, egress: &egress, gateways: &gateways)
        }

        return TopologySnapshot(
            machineModel: Self.machineModel(),
            interfaces: interfaces,
            routes: routes,
            gateways: gateways,
            hardwarePorts: usb.ports + tb.ports,
            attachedDevices: usb.devices + tb.devices + linuxDisplays() + linuxBluetoothDevices(),
            egress: egress,
            systemPower: linuxSystemPower(),
            dnsConfigs: linuxDNSConfigs())
    }

    /// DMI product name (e.g. "MacBookPro18,3", "20XW…"); "Linux" when unreadable.
    private static func machineModel() -> String {
        let name = (try? String(contentsOfFile: "/sys/devices/virtual/dmi/id/product_name", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty == false) ? name! : "Linux"
    }
}
#endif

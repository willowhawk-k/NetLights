#if os(Linux)
import Foundation
import NetLightsCore

/// L0 STUB collector. Proves the pipeline (Core → snapshot → JSON) compiles and runs on
/// Linux; real acquisition — getifaddrs, /proc/net/route, /sys/class/net statistics,
/// systemd-resolved DNS, then the USB/Thunderbolt/DRM-EDID/nl80211/BlueZ collectors —
/// lands in L1 and L3. Returns a near-empty snapshot with just the machine model.
struct LinuxCollector {
    func snapshot() -> TopologySnapshot {
        TopologySnapshot(machineModel: Self.machineModel())
    }

    /// DMI product name (e.g. "20XW…", "MacBookPro18,3"); "Linux" when unreadable.
    private static func machineModel() -> String {
        let path = "/sys/devices/virtual/dmi/id/product_name"
        let name = (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty == false) ? name! : "Linux"
    }
}
#endif

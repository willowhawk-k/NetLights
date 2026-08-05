#if os(Linux)
import Foundation
import NetLightsCore

// L3 Wi-Fi: the SSID and the negotiated link rate for a wireless uplink.
//
// WHY A SUBPROCESS AND NOT NETLINK. sysfs knows a device is wireless
// (/sys/class/net/<if>/wireless, phy80211 — which is already what linuxCategory tests) but
// carries NO SSID: the association state lives in nl80211 only. Getting it natively means a
// generic-netlink family resolution followed by an NL80211_CMD_GET_INTERFACE round-trip,
// hand-rolling netlink attribute TLVs — several hundred lines of byte-level code with no way
// to test it from macOS, to obtain one label. The DNS collector already set the precedent of
// shelling out to an optional binary (resolvectl) and degrading when it isn't there, so the
// same trade applies here. Raw nl80211 stays on the table if `iw` turns out to be commonly
// absent in practice.
//
// Note /sys/class/net/<if>/speed is meaningless for wireless (the driver reports -1 or
// nothing), so the link rate has to come from the same place as the SSID.

private func runCapturing(_ candidates: [String], _ args: [String]) -> String? {
    guard let exe = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
}

/// `iw dev <if> link`, or nil when iw is absent (it lives in the `iw` package, which a
/// minimal server install often omits) or the interface isn't associated.
private func iwLink(_ iface: String) -> String? {
    runCapturing(["/usr/sbin/iw", "/sbin/iw", "/usr/bin/iw", "/bin/iw"], ["dev", iface, "link"])
}

/// NetworkManager's view, as a fallback when `iw` is missing but nmcli is present.
private func nmcliSSID() -> String? {
    guard let out = runCapturing(["/usr/bin/nmcli", "/bin/nmcli"],
                                 ["-t", "-f", "active,ssid", "dev", "wifi"]) else { return nil }
    for line in out.split(separator: "\n") where line.hasPrefix("yes:") {
        let ssid = String(line.dropFirst(4))
        if !ssid.isEmpty { return ssid }
    }
    return nil
}

/// The SSID and negotiated rate for a wireless interface. Both degrade to nil independently.
func linuxWiFiLink(_ iface: String) -> (ssid: String?, bitrateBps: UInt64?) {
    if let text = iwLink(iface) {
        let link = parseIwLink(text)
        if link.ssid != nil || link.bitrateBps != nil {
            return (link.ssid ?? nmcliSSID(), link.bitrateBps)
        }
    }
    return (nmcliSSID(), nil)
}

/// The first associated wireless interface, using the same sysfs test as `linuxCategory` —
/// the presence of a `wireless`/`phy80211` node, never a name prefix.
func linuxWirelessInterfaces() -> [String] {
    let fm = FileManager.default
    return ((try? fm.contentsOfDirectory(atPath: "/sys/class/net")) ?? []).sorted().filter {
        fm.fileExists(atPath: "/sys/class/net/\($0)/wireless")
            || fm.fileExists(atPath: "/sys/class/net/\($0)/phy80211")
    }
}
#endif

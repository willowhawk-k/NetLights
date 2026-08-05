#if os(Linux)
import Foundation
import NetLightsCore

// L3 display collector: read each /sys/class/drm connector's status, raw EDID and mode list,
// and hand them to the pure builder in Core (EDIDParsing.swift).
//
// This is a parity WIN over the macOS build, not just parity. A sandboxed macOS app gets the
// display's vendor id, resolution and refresh but never a model name; Linux hands over the
// monitor's raw EDID, so the chip can be labelled with the actual product ("CU34G2XP") and
// its high-refresh modes read out of the CTA-861 extension block.
//
// All plain file reads, unprivileged, no libdrm.

private let drmRoot = "/sys/class/drm"

private func readText(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// The EDID as raw bytes. A disconnected connector's `edid` file exists and reads ZERO
/// bytes — that is the ordinary no-display case, not an error.
private func readEDID(_ path: String) -> [UInt8] {
    guard let d = FileManager.default.contents(atPath: path) else { return [] }
    return [UInt8](d)
}

func linuxDisplays() -> [AttachedDevice] {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: drmRoot)) ?? []).sorted()
    var readings: [DRMConnectorReading] = []
    for name in names {
        // Skips "card0", "renderD128", "version" and anything else that isn't a connector.
        guard let connector = parseDRMConnectorName(name), connector.isExternalOutput else { continue }
        let dir = "\(drmRoot)/\(name)"
        readings.append(DRMConnectorReading(
            connector: connector,
            status: readText("\(dir)/status"),
            edid: readEDID("\(dir)/edid"),
            modes: readText("\(dir)/modes")))
    }
    return buildDisplayDevices(readings)
}
#endif

import Foundation

// EDID + DRM connector parsing for the Linux display collector.
//
// Pure, like DNSParsing.swift and for the same reason: the implementer has no shell on the
// Linux test VM, so the only test signal available is feeding captured real bytes to these
// functions from macOS. The Linux side (LinuxDisplays.swift) does nothing but read files.
//
// This is a genuine parity WIN over the macOS build. macOS gives a sandboxed app the
// display's vendor id, resolution and refresh, but never a model name and never which
// connector it is on. Linux hands over the monitor's raw EDID, so NetLights can show the
// actual product name ("CU34G2XP") and the connector ("HDMI-A-2").

// MARK: - Types

public struct EDIDTiming: Equatable, Sendable {
    public var hActive: Int
    public var hBlank: Int
    public var vActive: Int
    public var vBlank: Int
    public var pixelClockKHz: Int      // stored in kHz (the EDID's 10 kHz units × 10)
    public var interlaced: Bool
    public var refreshHz: Double       // 0 when the totals are degenerate

    public init(hActive: Int, hBlank: Int, vActive: Int, vBlank: Int,
                pixelClockKHz: Int, interlaced: Bool, refreshHz: Double) {
        self.hActive = hActive; self.hBlank = hBlank
        self.vActive = vActive; self.vBlank = vBlank
        self.pixelClockKHz = pixelClockKHz
        self.interlaced = interlaced; self.refreshHz = refreshHz
    }
}

public struct EDIDInfo: Equatable, Sendable {
    public var manufacturerPnP: String    // always three uppercase letters
    public var productCode: Int
    public var serialNumber: UInt32
    public var manufactureWeek: Int?
    public var manufactureYear: Int?
    public var version: String            // "1.4"
    public var monitorName: String?       // 0xFC descriptor — the product name
    public var serialText: String?        // 0xFF
    public var asciiText: String?         // 0xFE
    public var preferredTiming: EDIDTiming?
    public var minVerticalHz: Int?
    public var maxVerticalHz: Int?
    public var extensionCount: Int
    public var checksumValid: Bool
}

public struct DRMMode: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var interlaced: Bool
    public init(width: Int, height: Int, interlaced: Bool) {
        self.width = width; self.height = height; self.interlaced = interlaced
    }
}

public struct DRMConnector: Equatable, Sendable {
    public var directoryName: String      // "card0-HDMI-A-2"
    public var cardIndex: Int
    public var typeName: String           // "HDMI-A"
    public var index: String              // "2", or "1-1" for a DisplayPort-MST branch
    public var shortName: String          // "HDMI-A-2"
    public var isInternalPanel: Bool      // eDP / LVDS / DSI — the built-in laptop screen
    public var isPhysicalOutput: Bool     // false for Writeback / Unknown pseudo-connectors

    /// What the collector actually wants: a real, external display connector.
    public var isExternalOutput: Bool { isPhysicalOutput && !isInternalPanel }
}

// MARK: - DRM sysfs

/// Parse a /sys/class/drm directory name. Has to cope with two-token type names
/// ("HDMI-A-2") and DisplayPort-MST branch suffixes ("DP-1-1"), so it can't simply split
/// on the last "-".
public func parseDRMConnectorName(_ dir: String) -> DRMConnector? {
    guard dir.hasPrefix("card") else { return nil }
    let afterCard = dir.dropFirst(4)
    let digits = afterCard.prefix { $0.isNumber }
    guard !digits.isEmpty, let card = Int(digits) else { return nil }
    let rest = afterCard.dropFirst(digits.count)
    guard rest.hasPrefix("-") else { return nil }     // "card0" alone is the card, not a connector

    let parts = rest.dropFirst().split(separator: "-", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2 else { return nil }
    // The type is the leading run of non-numeric components; the rest is the index.
    var typeParts: [String] = []
    var i = 0
    while i < parts.count, !(parts[i].allSatisfy(\.isNumber) && !parts[i].isEmpty) {
        typeParts.append(parts[i]); i += 1
    }
    let indexParts = Array(parts[i...])
    guard !typeParts.isEmpty, !indexParts.isEmpty else { return nil }

    let type = typeParts.joined(separator: "-")
    let index = indexParts.joined(separator: "-")
    let lower = type.lowercased()
    return DRMConnector(
        directoryName: dir, cardIndex: card, typeName: type, index: index,
        shortName: "\(type)-\(index)",
        isInternalPanel: ["edp", "lvds", "dsi", "dpi", "spi"].contains(lower),
        // A Writeback connector always reports "connected" and is not a monitor; "Virtual"
        // IS kept, because in a VM it's the real display.
        isPhysicalOutput: !["writeback", "unknown"].contains(lower))
}

public func drmStatusIsConnected(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines) == "connected"
}

/// Parse the `modes` file — one mode per line, "3440x1440", with an optional trailing "i"
/// for interlaced. Anything else is skipped rather than treated as an error.
public func parseDRMModes(_ text: String) -> [DRMMode] {
    var out: [DRMMode] = []
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { continue }
        var body = Substring(line)
        var interlaced = false
        if body.hasSuffix("i") { interlaced = true; body = body.dropLast() }
        let xy = body.split(separator: "x", omittingEmptySubsequences: false)
        guard xy.count == 2, let w = Int(xy[0]), let h = Int(xy[1]), w > 0, h > 0 else { continue }
        out.append(DRMMode(width: w, height: h, interlaced: interlaced))
    }
    return out
}

// MARK: - EDID

private let edidMagic: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]

/// Decode the 128-byte EDID base block.
///
/// The checksum is recorded but NOT fatal: KVMs, DP/HDMI adapters and cheap docks routinely
/// rewrite an EDID and leave the checksum stale, and refusing those means showing no monitor
/// at all. The header magic plus three valid 5-bit letters is already a very strong guard
/// against reading garbage.
public func parseEDID(_ bytes: [UInt8]) -> EDIDInfo? {
    guard bytes.count >= 128, Array(bytes[0..<8]) == edidMagic else { return nil }
    let b = bytes

    // Manufacturer: bytes 8-9 big-endian, three 5-bit letters, 1 = 'A'.
    let id = (UInt16(b[8]) << 8) | UInt16(b[9])
    func letter(_ shift: UInt16) -> Character? {
        let code = Int((id >> shift) & 0x1F)
        guard code >= 1, code <= 26 else { return nil }
        return Character(UnicodeScalar(UInt8(code + 64)))
    }
    guard let c1 = letter(10), let c2 = letter(5), let c3 = letter(0) else { return nil }

    var info = EDIDInfo(
        manufacturerPnP: String([c1, c2, c3]),
        productCode: Int(b[10]) | (Int(b[11]) << 8),
        serialNumber: UInt32(b[12]) | (UInt32(b[13]) << 8)
                    | (UInt32(b[14]) << 16) | (UInt32(b[15]) << 24),
        manufactureWeek: (1...54).contains(Int(b[16])) ? Int(b[16]) : nil,
        manufactureYear: b[17] == 0 ? nil : 1990 + Int(b[17]),
        version: "\(b[18]).\(b[19])",
        monitorName: nil, serialText: nil, asciiText: nil, preferredTiming: nil,
        minVerticalHz: nil, maxVerticalHz: nil,
        extensionCount: Int(b[126]),
        // Accumulate in Int: a UInt8 accumulator traps on overflow in Swift.
        checksumValid: b[0..<128].reduce(0) { $0 + Int($1) } % 256 == 0)

    for i in 0..<4 {
        let d = Array(b[(54 + 18 * i)..<(72 + 18 * i)])
        if d[0] == 0 && d[1] == 0 && d[2] == 0 {
            switch d[3] {
            case 0xFC: if info.monitorName == nil { info.monitorName = decodeEDIDString(d) }
            case 0xFF: if info.serialText == nil { info.serialText = decodeEDIDString(d) }
            case 0xFE: if info.asciiText == nil { info.asciiText = decodeEDIDString(d) }
            case 0xFD:
                var minV = Int(d[5]), maxV = Int(d[6])
                // EDID 1.4 stores 255 Hz offsets in d[4] bits 1:0 (vertical).
                if d[4] & 0b10 != 0 { maxV += 255 }
                if d[4] & 0b11 == 0b11 { minV += 255 }
                info.minVerticalHz = minV == 0 ? nil : minV
                info.maxVerticalHz = maxV == 0 ? nil : maxV
            default: break
            }
        } else if i == 0 {
            info.preferredTiming = parseEDIDDetailedTiming(d)
        }
    }
    return info
}

/// A descriptor's 13-byte text payload: terminated by 0x0A, space-padded, ASCII only.
private func decodeEDIDString(_ d: [UInt8]) -> String? {
    var payload = Array(d[5..<18])
    if let nl = payload.firstIndex(of: 0x0A) { payload = Array(payload[..<nl]) }
    while let last = payload.last, last == 0x20 || last == 0x00 { payload.removeLast() }
    // Drop anything non-printable rather than risking a replacement character in the graph.
    let s = String(payload.filter { (0x20...0x7E).contains($0) }.map { Character(UnicodeScalar($0)) })
    return s.isEmpty ? nil : s
}

/// One 18-byte detailed timing descriptor. The EDID splits each value across a low byte and
/// a nibble of a shared high byte, which is why every field is a two-part reassembly.
public func parseEDIDDetailedTiming(_ d: [UInt8]) -> EDIDTiming? {
    guard d.count >= 18 else { return nil }
    let clock10kHz = Int(d[0]) | (Int(d[1]) << 8)
    guard clock10kHz > 0 else { return nil }          // a zero clock means "not a timing"

    let hActive = Int(d[2]) | ((Int(d[4]) & 0xF0) << 4)
    let hBlank  = Int(d[3]) | ((Int(d[4]) & 0x0F) << 8)
    let vActive = Int(d[5]) | ((Int(d[7]) & 0xF0) << 4)
    let vBlank  = Int(d[6]) | ((Int(d[7]) & 0x0F) << 8)
    guard hActive > 0, vActive > 0 else { return nil }

    let interlaced = (d[17] & 0x80) != 0
    let hTotal = hActive + hBlank, vTotal = vActive + vBlank
    let refresh = (hTotal > 0 && vTotal > 0)
        ? Double(clock10kHz) * 10_000.0 / Double(hTotal * vTotal) : 0

    return EDIDTiming(hActive: hActive, hBlank: hBlank, vActive: vActive, vBlank: vBlank,
                      pixelClockKHz: clock10kHz * 10, interlaced: interlaced,
                      refreshHz: refresh)
}

/// Every detailed timing in the whole blob — base block first, then each CTA-861 extension
/// block, in file order.
///
/// This matters more than it looks. A high-refresh monitor's BASE block advertises a
/// conservative preferred timing (the developer's own 180 Hz AOC declares 59.97 Hz there);
/// the 100/120/144/180 Hz modes live in the CTA-861 extension. Reading only the base block
/// would label a 180 Hz display "@ 60 Hz" — and macOS, which reads the mode the display is
/// actually running, would disagree with Linux on the same monitor.
public func edidDetailedTimings(_ bytes: [UInt8]) -> [EDIDTiming] {
    guard bytes.count >= 128, Array(bytes[0..<8]) == edidMagic else { return [] }
    var out: [EDIDTiming] = []

    // Base block: descriptors 1-4, but only those that are timings (a display descriptor
    // has three leading zero bytes).
    for i in 0..<4 {
        let d = Array(bytes[(54 + 18 * i)..<(72 + 18 * i)])
        guard !(d[0] == 0 && d[1] == 0 && d[2] == 0) else { continue }
        if let t = parseEDIDDetailedTiming(d) { out.append(t) }
    }

    // Extension blocks. Only CTA-861 (tag 0x02) carries DTDs at a self-described offset;
    // DisplayID (0x70), block maps (0xF0) and the rest must be skipped rather than walked,
    // or their payload decodes as garbage timings.
    let declared = Int(bytes[126])
    let available = (bytes.count / 128) - 1
    for e in 0..<min(declared, available) {
        let base = 128 * (e + 1)
        let block = Array(bytes[base..<(base + 128)])
        guard block[0] == 0x02 else { continue }
        let dtdStart = Int(block[2])
        // 0 means "no DTDs"; 1..3 are reserved values, not offsets.
        guard dtdStart >= 4, dtdStart <= 127 - 18 else { continue }
        var off = dtdStart
        while off + 18 <= 127 {
            let d = Array(block[off..<(off + 18)])
            // A zero pixel clock terminates the DTD list (the remainder is padding).
            if d[0] == 0 && d[1] == 0 { break }
            if let t = parseEDIDDetailedTiming(d) { out.append(t) }
            off += 18
        }
    }
    return out
}

/// The timing that best represents the display: the highest refresh rate available at the
/// preferred (native) resolution. Falls back to the preferred timing, then to anything.
public func edidBestTiming(_ bytes: [UInt8]) -> EDIDTiming? {
    let all = edidDetailedTimings(bytes)
    guard let native = all.first else { return nil }
    let atNative = all.filter { $0.hActive == native.hActive && $0.vActive == native.vActive }
    return atNative.max { $0.refreshHz < $1.refreshHz } ?? native
}

/// The Devices-table / tooltip label for a display mode. Shared with the macOS probe so a
/// monitor reads identically on both platforms — the separator is U+00D7 with a space
/// either side, and the refresh is rounded half-away-from-zero.
public func displayDetailLabel(width: Int, height: Int, refreshHz: Double) -> String? {
    guard width > 0, height > 0 else { return nil }
    guard refreshHz > 0 else { return "\(width) × \(height)" }
    return "\(width) × \(height) @ \(Int(refreshHz.rounded())) Hz"
}

/// PnP id → a human vendor name, falling back to the three-letter code. Shared with the
/// macOS display probe so both platforms label the same monitor identically.
public func pnpVendorDisplayName(_ pnp: String) -> String {
    let known = ["GSM": "LG", "BNQ": "BenQ", "DEL": "Dell", "APP": "Apple",
                 "SAM": "Samsung", "ACR": "Acer", "AUS": "ASUS", "HWP": "HP",
                 "LEN": "Lenovo", "PHL": "Philips", "VSC": "ViewSonic",
                 "GGL": "Google", "SNY": "Sony", "MSI": "MSI", "AOC": "AOC",
                 "NEC": "NEC", "EIZ": "EIZO", "HPN": "HP"]
    return known[pnp] ?? pnp
}

// MARK: - Building the model

/// One connector's raw inputs, gathered by the Linux side.
public struct DRMConnectorReading: Sendable {
    public let connector: DRMConnector
    public let status: String
    public let edid: [UInt8]
    public let modes: String
    public init(connector: DRMConnector, status: String, edid: [UInt8], modes: String) {
        self.connector = connector; self.status = status; self.edid = edid; self.modes = modes
    }
}

/// Turn connector readings into display chips under the Displays entity (receptacle -2).
/// Lives in Core because `AttachedDevice` has no public initializer — the Linux module can
/// pass strings and bytes in, but cannot construct the model itself.
public func buildDisplayDevices(_ readings: [DRMConnectorReading]) -> [AttachedDevice] {
    var out: [AttachedDevice] = []
    for r in readings where r.connector.isExternalOutput && drmStatusIsConnected(r.status) {
        let info = parseEDID(r.edid)
        let vendor = info.map { pnpVendorDisplayName($0.manufacturerPnP) }
        // The EDID's monitor-name descriptor is the actual product name — something the
        // sandboxed macOS build can't see at all.
        let name = info?.monitorName
            ?? vendor.map { "\($0) Display" }
            ?? "Display (\(r.connector.shortName))"

        // Best timing at the native resolution, which means walking the CTA-861 extension
        // where a high-refresh monitor keeps its 100/144/180 Hz modes. Falls back to the
        // first advertised sysfs mode, which has a resolution but no refresh rate — the
        // usual shape inside a VM whose host synthesizes no EDID.
        var detail: String?
        if let t = edidBestTiming(r.edid) {
            detail = displayDetailLabel(width: t.hActive, height: t.vActive, refreshHz: t.refreshHz)
        } else if let m = parseDRMModes(r.modes).first {
            detail = displayDetailLabel(width: m.width, height: m.height, refreshHz: 0)
        }

        out.append(AttachedDevice(
            id: "disp-\(r.connector.shortName)",
            name: name,
            receptacle: -2,
            kind: .display,
            vendorName: vendor,
            serial: info.flatMap { $0.serialText },
            detail: detail,
            connection: "Display"))
    }
    // Stable order: connector name. Snapshots are meant to be reproducible.
    return out.sorted { $0.id < $1.id }
}

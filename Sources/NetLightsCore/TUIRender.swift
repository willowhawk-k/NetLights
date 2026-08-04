import Foundation

// The top(1)-style terminal UI, as a PURE function: snapshot + state in, one screen-worth
// of ANSI text out. No I/O, no termios, no platform imports — the terminal driver in
// NetLightsTerm does all of that and just prints what this returns.
//
// It lives in NetLightsCore for the same reason GraphSVGRenderer does: every stored
// property of InterfaceInfo/RouteEntry/AttachedDevice/DNSConfig is `internal`, so a
// renderer outside Core would force ~80 declarations public. Inside Core it reads them
// directly and exports a handful of symbols.
//
// Views, keys and columns intentionally mirror the macOS tab bar and the Linux web UI so
// the three surfaces read as one product.

// MARK: - Display width

/// Terminal cells occupied by a string. NOT `String.count`: a CJK glyph is one grapheme
/// but two cells, and device names / SSIDs routinely carry CJK, emoji and combining
/// marks — using `count` shifts every column after them. (`String.padding(toLength:)` is
/// UTF-16-based and Foundation-flavored, so it's wrong here too.)
public func displayWidth(_ s: String) -> Int {
    var w = 0
    for scalar in s.unicodeScalars {
        switch scalar.value {
        case 0x0300...0x036F, 0x200B...0x200F, 0xFE00...0xFE0F:
            continue                        // combining marks / zero-width / variation selectors
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3,
             0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF,
             0x20000...0x3FFFD:
            w += 2                          // East Asian Wide / Fullwidth / emoji
        default:
            w += 1
        }
    }
    return w
}

/// Replace control characters with a visible placeholder before anything reaches the
/// terminal. Snapshot strings are ATTACKER-INFLUENCED: a USB product string, a Wi-Fi SSID
/// and a DHCP-supplied search domain are all chosen by someone else, and any of them can
/// carry ESC. Unfiltered, a device name containing `ESC[2J ESC[1;1H` repaints the
/// operator's screen with content of its choosing — it can blank the display, fake rows, or
/// hide an interface. Applied in `clip`, which every rendered cell goes through.
func sanitizeForTerminal(_ s: String) -> String {
    guard s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F
                                             || (0x80...0x9F).contains($0.value) })
    else { return s }                      // fast path: the overwhelming majority
    var out = String.UnicodeScalarView()
    for u in s.unicodeScalars {
        if u.value < 0x20 || u.value == 0x7F || (0x80...0x9F).contains(u.value) {
            out.append("\u{FFFD}")         // C0, DEL and C1 — includes ESC (0x1B)
        } else {
            out.append(u)
        }
    }
    return String(out)
}

/// Truncate to `width` cells, marking elision. Width-aware on both ends.
func clip(_ raw: String, _ width: Int, unicode: Bool) -> String {
    guard width > 0 else { return "" }
    // Single choke point for escape-sequence neutering: every column in every view is
    // rendered through cell() -> clip().
    let s = sanitizeForTerminal(raw)
    if displayWidth(s) <= width { return s }
    let ell = unicode ? "…" : "."
    let budget = width - displayWidth(ell)
    var out = "", w = 0
    for ch in s {
        let cw = displayWidth(String(ch))
        if w + cw > budget { break }
        out.append(ch); w += cw
    }
    return out + ell
}

/// Clip an already-coloured line to `width` VISIBLE cells, stepping over ANSI escape
/// sequences (which occupy no cells). The plain `clip` can't be used on a rendered row:
/// it would count the escape bytes as characters and cut the line far too short.
/// Auto-wrap is disabled while the TUI runs, so anything past the edge would be dropped by
/// the terminal instead — this makes the truncation ours, and predictable.
func clipToWidth(_ s: String, _ width: Int) -> String {
    var out = "", w = 0, sawEscape = false
    var i = s.startIndex
    while i < s.endIndex {
        let ch = s[i]
        if ch == "\u{1B}" {
            out.append(ch)
            sawEscape = true
            var j = s.index(after: i)
            while j < s.endIndex {
                let c = s[j]
                out.append(c)
                j = s.index(after: j)
                if c.isLetter { break }      // final byte of the CSI sequence
            }
            i = j
            continue
        }
        let cw = displayWidth(String(ch))
        if w + cw > width {
            return sawEscape ? out + "\u{1B}[0m" : out   // never leave colour bleeding
        }
        out.append(ch); w += cw
        i = s.index(after: i)
    }
    return out
}

/// Pad (or clip) to exactly `width` cells.
func cell(_ s: String, _ width: Int, unicode: Bool = true) -> String {
    let t = clip(s, width, unicode: unicode)
    return t + String(repeating: " ", count: max(0, width - displayWidth(t)))
}

// MARK: - Colour

/// The product palette, mapped from the SVG/web hex tokens so the TUI reads as the same
/// app. Degrades 256 → 16 → none; the driver picks the tier from TERM/NO_COLOR/isatty.
public enum TUIColor {
    case up, down, unknown, wifi, amber, purple, teal, pink, muted, dim, headline

    fileprivate var xterm: Int {
        switch self {
        case .up: return 71          // #3fb950
        case .down: return 203       // #f85149
        case .unknown, .muted: return 246 // #8b949e
        case .wifi: return 75        // #58a6ff
        case .amber: return 214      // #f0a022
        case .purple: return 135     // #a371f7
        case .teal: return 43        // #2dd4bf
        case .pink: return 169       // #db61a2
        case .dim: return 243        // #6e7681
        case .headline: return 80    // #39c5cf
        }
    }
    fileprivate var ansi16: Int {
        switch self {
        case .up: return 92
        case .down: return 91
        case .unknown, .muted, .dim: return 90
        case .wifi: return 94
        case .amber: return 93
        case .purple, .pink: return 95
        case .teal, .headline: return 96
        }
    }
}

func paint(_ s: String, _ c: TUIColor, _ mode: TUIColorMode) -> String {
    switch mode {
    case .none:     return s
    case .ansi16:   return "\u{1B}[\(c.ansi16)m\(s)\u{1B}[0m"
    case .xterm256: return "\u{1B}[38;5;\(c.xterm)m\(s)\u{1B}[0m"
    }
}

/// Reverse video — used for the active tab and section rules so the UI still parses with
/// colour disabled, which is what makes the no-colour tier genuinely usable.
func reverse(_ s: String, _ mode: TUIColorMode) -> String {
    mode == .none ? "[\(s)]" : "\u{1B}[7m\(s)\u{1B}[27m"
}

func bold(_ s: String, _ mode: TUIColorMode) -> String {
    mode == .none ? s : "\u{1B}[1m\(s)\u{1B}[22m"
}

// MARK: - Keys

public enum TUIKey: Equatable, Sendable {
    case view(TUIView)
    case quit
    case toggleHideInactive
    case togglePrivacy
    case toggleSort
    case togglePause
    case help
    case scroll(Int)      // rows; negative is up
    case home, end
    case redraw
    case none
}

/// Decode raw bytes from the terminal. Pure and unit-testable — a held key or a paste
/// delivers several bytes at once, and CSI sequences (arrows, PgUp/PgDn) span 3-4 bytes.
/// Bare ESC is deliberately NOT bound to quit: it's ambiguous with a sequence prefix.
public func decodeTUIKeys(_ bytes: ArraySlice<UInt8>) -> [TUIKey] {
    var keys: [TUIKey] = []
    var i = bytes.startIndex
    while i < bytes.endIndex {
        let b = bytes[i]
        if b == 0x1B, bytes.index(after: i) < bytes.endIndex, bytes[bytes.index(after: i)] == 0x5B {
            // CSI: ESC [ …
            var j = bytes.index(i, offsetBy: 2)
            var params = ""
            while j < bytes.endIndex, (0x30...0x3F).contains(bytes[j]) {
                params.append(Character(UnicodeScalar(bytes[j])))
                j = bytes.index(after: j)
            }
            guard j < bytes.endIndex else { break }
            switch bytes[j] {
            case 0x41: keys.append(.scroll(-1))          // Up
            case 0x42: keys.append(.scroll(1))           // Down
            case 0x48: keys.append(.home)                // Home
            case 0x46: keys.append(.end)                 // End
            case 0x7E:
                switch params {
                case "5": keys.append(.scroll(-10))      // PgUp
                case "6": keys.append(.scroll(10))       // PgDn
                case "1", "7": keys.append(.home)
                case "4", "8": keys.append(.end)
                default: break
                }
            default: break
            }
            i = bytes.index(after: j)
            continue
        }
        switch b {
        case 0x03, 0x04:                 keys.append(.quit)   // Ctrl-C / Ctrl-D
        case UInt8(ascii: "q"), UInt8(ascii: "Q"): keys.append(.quit)
        case UInt8(ascii: "g"), UInt8(ascii: "1"): keys.append(.view(.graph))
        case UInt8(ascii: "r"), UInt8(ascii: "2"): keys.append(.view(.routes))
        case UInt8(ascii: "i"), UInt8(ascii: "3"): keys.append(.view(.interfaces))
        case UInt8(ascii: "d"), UInt8(ascii: "4"): keys.append(.view(.devices))
        case UInt8(ascii: "n"), UInt8(ascii: "5"): keys.append(.view(.dns))
        case UInt8(ascii: "h"):          keys.append(.toggleHideInactive)
        case UInt8(ascii: "p"):          keys.append(.togglePrivacy)
        case UInt8(ascii: "s"):          keys.append(.toggleSort)
        case UInt8(ascii: " "):          keys.append(.togglePause)
        case UInt8(ascii: "?"):          keys.append(.help)
        case 0x0C:                       keys.append(.redraw) // Ctrl-L
        default: break
        }
        i = bytes.index(after: i)
    }
    return keys
}

// MARK: - State

public struct TUIState: Equatable, Sendable {
    public var view: TUIView = .graph
    public var hideInactive = false
    public var privacy = false
    public var sortNumeric = false
    public var paused = false
    public var showHelp = false
    public var scroll = 0
    public init() {}

    /// Apply a key. Returns false when the user asked to quit.
    public mutating func apply(_ key: TUIKey) -> Bool {
        switch key {
        case .quit: return false
        case .view(let v): view = v; scroll = 0; showHelp = false
        case .toggleHideInactive: hideInactive.toggle()
        case .togglePrivacy: privacy.toggle()
        case .toggleSort: sortNumeric.toggle()
        case .togglePause: paused.toggle()
        case .help: showHelp.toggle()
        case .scroll(let d): scroll = max(0, scroll + d)
        case .home: scroll = 0
        case .end: scroll = Int.max / 2
        case .redraw, .none: break
        }
        return true
    }
}

// MARK: - Privacy masking

/// Keeps the IPv4 first octet / MAC OUI, matching the GUI's privacy mode. Hand-rolled
/// rather than NSRegularExpression: this must run in the static musl build, where
/// leaning on plain stdlib string ops is the safer bet.
func maskIfNeeded(_ s: String, _ on: Bool) -> String {
    guard on, !s.isEmpty else { return s }
    if s.contains(":") {                       // MAC — keep the vendor OUI
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return s }
        return parts.prefix(3).joined(separator: ":") + ":xx:xx:xx"
    }
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return s }
    if s.hasPrefix("127.") { return s }        // loopback stays legible, as in the GUI
    return "\(parts[0]).x.x.x"
}

// MARK: - Frame

public struct TUIFrame: Sendable {
    public var columns: Int
    public var rows: Int
    public var colorMode: TUIColorMode
    public var unicode: Bool
    public var clockLabel: String
    public var versionLabel: String
    public init(columns: Int, rows: Int, colorMode: TUIColorMode,
                unicode: Bool, clockLabel: String, versionLabel: String) {
        self.columns = columns; self.rows = rows; self.colorMode = colorMode
        self.unicode = unicode; self.clockLabel = clockLabel; self.versionLabel = versionLabel
    }
}

/// Build one full screen. Returns rows WITHOUT trailing newlines — the driver joins them
/// with `ESC[K\r\n` so each line self-erases (top(1)'s trick: no full-screen clear, no
/// flicker).
public func renderTUIFrame(snapshot: TopologySnapshot,
                           rates: TrafficRateDeriver,
                           state: TUIState,
                           frame: TUIFrame) -> [String] {
    let w = max(frame.columns, 20)
    if w < 60 {
        // Short lines, and clipped anyway — a "too narrow" notice that itself overflows
        // would be a poor joke.
        return ["NetLights", "", "Terminal too narrow.", "Widen to 60+ columns.",
                "(now \(frame.columns))"].map { clipToWidth($0, w) }
    }
    var out: [String] = []
    out.append(contentsOf: header(snapshot, state, frame, w))

    let bodyRows = max(3, frame.rows - out.count - 1)   // -1 for the footer
    var body: [String]
    if state.showHelp {
        body = helpOverlay(frame)
    } else {
        switch state.view {
        case .graph:      body = graphView(snapshot, rates, state, frame, w)
        case .interfaces: body = interfacesView(snapshot, rates, state, frame, w)
        case .routes:     body = routesView(snapshot, state, frame, w)
        case .devices:    body = devicesView(snapshot, state, frame, w)
        case .dns:        body = dnsView(snapshot, state, frame, w)
        }
    }
    // Clamp scroll to what's actually there, then window it.
    let maxScroll = max(0, body.count - bodyRows)
    let start = min(state.scroll, maxScroll)
    let windowed = Array(body.dropFirst(start).prefix(bodyRows))
    // Single choke point: every body row is clipped to the terminal width here, so no view
    // has to get its column arithmetic exactly right at every size.
    out.append(contentsOf: windowed.map { clipToWidth($0, w) })
    // Pad so the footer sits on the last row.
    while out.count < frame.rows - 1 { out.append("") }
    out.append(footer(state, frame, w, more: maxScroll > start))
    return out
}

// MARK: - Header / footer

private func header(_ s: TopologySnapshot, _ st: TUIState,
                    _ f: TUIFrame, _ w: Int) -> [String] {
    let m = f.colorMode
    let up = s.interfaces.filter { $0.linkState == .up }.count
    var bits: [String] = ["NetLights \(f.versionLabel)"]
    if !s.machineModel.isEmpty { bits.append(s.machineModel) }
    if let e = s.egress {
        bits.append("egress \(e.viaInterface) (\(maskIfNeeded(e.displayName, st.privacy)))")
    }
    bits.append("\(up)/\(s.interfaces.count) up")
    if !s.gateways.isEmpty { bits.append("\(s.gateways.count) gw") }
    if !s.attachedDevices.isEmpty { bits.append("\(s.attachedDevices.count) dev") }
    if let p = s.systemPower?.label { bits.append(p) }
    bits.append(f.clockLabel)
    let line1 = cell(bits.joined(separator: " · "), w, unicode: f.unicode)

    // Tab bar, active tab in reverse video. Track the VISIBLE width as we build: with
    // colour off, `reverse` degrades to [brackets], which occupy two real cells that a
    // width computed from the raw labels would miss — and the line would run off the edge.
    var tabs = ""
    var tabsWidth = 0
    for v in TUIView.allCases {
        let t = " \(v.hotkey) \(v.title) "
        if v == st.view {
            tabs += reverse(t, m)
            tabsWidth += displayWidth(t) + (m == .none ? 2 : 0)
        } else {
            tabs += paint(t, .dim, m)
            tabsWidth += displayWidth(t)
        }
    }
    var flags: [String] = []
    if st.hideInactive { flags.append("hide:on") }
    if st.privacy      { flags.append("privacy:on") }
    if st.paused       { flags.append("PAUSED") }
    let right = flags.joined(separator: " ")
    let gap = max(1, w - tabsWidth - displayWidth(right))
    let line2 = tabs + String(repeating: " ", count: gap)
        + paint(right, st.paused ? .amber : .dim, m)
    return [bold(line1, m), line2]
}

private func footer(_ st: TUIState, _ f: TUIFrame, _ w: Int, more: Bool) -> String {
    let hint = "g/r/i/d/n or 1-5 view · h hide · p privacy · s sort · SPACE pause"
        + " · ↑↓/PgUp scroll · ? help · q quit"
    let ascii = "g/r/i/d/n or 1-5 view · h hide · p privacy · s sort · SPACE pause"
        + " · arrows scroll · ? help · q quit"
    let base = f.unicode ? hint : ascii
    return paint(cell(more ? base + "  ▾more" : base, w, unicode: f.unicode), .dim, f.colorMode)
}

private func helpOverlay(_ f: TUIFrame) -> [String] {
    netLightsHelpText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        + ["", "Press ? to close."]
}

private func rule(_ title: String, _ w: Int, _ f: TUIFrame, _ c: TUIColor) -> String {
    let dash = f.unicode ? "─" : "-"
    let label = " \(title) "
    let fill = max(0, w - displayWidth(label) - 4)
    return paint(String(repeating: dash, count: 3) + label
                 + String(repeating: dash, count: fill), c, f.colorMode)
}

private func dot(_ ls: LinkState, _ f: TUIFrame) -> String {
    let g = f.unicode ? "●" : "*"
    let o = f.unicode ? "○" : "o"
    switch ls {
    case .up:      return paint(g, .up, f.colorMode)
    case .down:    return paint(g, .down, f.colorMode)
    case .unknown: return paint(o, .unknown, f.colorMode)
    }
}

private func color(for c: InterfaceCategory) -> TUIColor {
    switch c {
    case .wifi:                return .wifi
    case .ethernet:            return .up
    case .cellular:            return .amber
    case .thunderbolt, .vlan:  return .purple
    case .bridge:              return .pink
    case .tunnel:              return .teal
    case .loopback, .awdl, .other: return .muted
    }
}

// MARK: - Views

private func visibleInterfaces(_ s: TopologySnapshot, _ st: TUIState,
                               _ rates: TrafficRateDeriver) -> [InterfaceInfo] {
    s.interfaces.filter {
        guard st.hideInactive else { return true }
        return !$0.isHiddenWhenInactive(active: rates.isActive($0.id))
    }
}

private func interfacesView(_ s: TopologySnapshot, _ rates: TrafficRateDeriver,
                            _ st: TUIState, _ f: TUIFrame, _ w: Int) -> [String] {
    // Columns drop by priority as the terminal narrows; S/IFACE/IPV4/RX·s/TX·s always stay.
    let wide = w >= 132, mid = w >= 104
    var head = "  " + cell("IFACE", 10) + cell("TYPE", 13)
    if wide { head += cell("DESCRIPTION", 18) }
    head += cell("IPV4", 16)
    if mid  { head += cell("MAC", 18) }
    head += cell("SPEED", 10) + cell("RX/s", 11) + cell("TX/s", 11)
    if wide { head += cell("RX", 10) + cell("TX", 10) }
    var rows = [paint(cell(head, w, unicode: f.unicode), .dim, f.colorMode)]

    for i in visibleInterfaces(s, st, rates) {
        var r = dot(i.linkState, f) + " "
        r += paint(cell(i.id, 10), color(for: i.category), f.colorMode)
        r += cell(i.category.rawValue, 13)
        // Prefer the SystemConfiguration hardware-port name ("Wi-Fi", "Thunderbolt 1"),
        // matching the macOS Interfaces tab, and fall back to subtitleLabel for interfaces
        // SC doesn't name. Not subtitleLabel first: it substitutes the IP address, which
        // is right for a graph node but duplicates the IPV4 column here.
        if wide { r += cell(i.displayName ?? i.subtitleLabel, 18) }
        r += cell(maskIfNeeded(i.ipv4Addresses.first ?? "—", st.privacy), 16)
        if mid { r += cell(maskIfNeeded(i.macAddress ?? "—", st.privacy), 18) }
        r += cell(i.formattedSpeed ?? "—", 10)
        let rx = formatRate(rates.rxRate(for: i.id)) ?? "—"
        let tx = formatRate(rates.txRate(for: i.id)) ?? "—"
        r += paint(cell(rx, 11), rates.state(for: i.id).rxActive ? .up : .dim, f.colorMode)
        r += paint(cell(tx, 11), rates.state(for: i.id).txActive ? .up : .dim, f.colorMode)
        if wide {
            r += cell(formatByteCount(i.rxBytes), 10) + cell(formatByteCount(i.txBytes), 10)
        }
        rows.append(r)
    }
    if rows.count == 1 { rows.append("  (no interfaces)") }
    return rows
}

private func routesView(_ s: TopologySnapshot, _ st: TUIState,
                        _ f: TUIFrame, _ w: Int) -> [String] {
    let head = "  " + cell("DESTINATION", 20) + cell("GATEWAY", 17)
        + cell("NETMASK", 17) + cell("IFACE", 9) + cell("FLAGS", 8)
    var rows: [String] = []

    func emit(_ list: [RouteEntry]) {
        for r in list.sorted(by: { routeSortKey($0.destination) < routeSortKey($1.destination) }) {
            var line = "  "
            let dest = r.isDefault ? "\(r.destination) \(f.unicode ? "✦" : "*")" : r.destination
            line += cell(maskIfNeeded(dest, st.privacy), 20)
            line += cell(maskIfNeeded(r.gateway.isEmpty ? "—" : r.gateway, st.privacy), 17)
            line += cell(maskIfNeeded(r.netmask ?? "—", st.privacy), 17)
            line += cell(r.interfaceName, 9) + cell(r.flags, 8)
            rows.append(line)
        }
    }

    if st.sortNumeric {
        // Flat, numerically sorted — the "s" toggle, matching the macOS Routes tab.
        rows.append(paint(cell(head, w, unicode: f.unicode), .dim, f.colorMode))
        emit(s.routes)
    } else {
        let g = classifyRoutes(s.routes, gateways: s.gateways)
        for (title, list, c) in [("Direct — split-tunnel (unencrypted)", g.direct, TUIColor.amber),
                                 ("Encrypted — VPN tunnel", g.encrypted, TUIColor.teal),
                                 ("Local", g.local, TUIColor.muted)] where !list.isEmpty {
            rows.append(rule(title, w, f, c))
            rows.append(paint(cell(head, w, unicode: f.unicode), .dim, f.colorMode))
            emit(list)
            rows.append("")
        }
    }
    if rows.isEmpty { rows = ["  (no routes)"] }
    return rows
}

private func devicesView(_ s: TopologySnapshot, _ st: TUIState,
                         _ f: TUIFrame, _ w: Int) -> [String] {
    guard !s.attachedDevices.isEmpty else {
        return ["", "  No external devices.",
                "  (On Linux, USB / Thunderbolt collectors arrive in a later update.)"]
    }
    let wide = w >= 120
    var head = "  " + cell("DEVICE", 30) + cell("TYPE", 12) + cell("VENDOR", 16)
        + cell("BUS", 11) + cell("SPEED", 15)
    if wide { head += cell("CLASS", 13) + cell("VID:PID", 11) }
    var rows = [paint(cell(head, w, unicode: f.unicode), .dim, f.colorMode)]

    // Pre-order walk so hubs own their children, mirroring the graph's device tree.
    let children = Dictionary(grouping: s.attachedDevices.filter { $0.parentID != nil },
                              by: { $0.parentID! })
    func walk(_ d: AttachedDevice, _ depth: Int) {
        let indent = String(repeating: "  ", count: min(depth, 8))
        var r = "  " + cell(indent + maskIfNeeded(d.name, st.privacy), 30)
        r += cell(d.kind.label, 12)
        r += cell(d.vendorName ?? "—", 16)
        r += cell(d.connectionLabel, 11)
        r += cell(d.speedLabel, 15)
        if wide { r += cell(d.classLabel, 13) + cell(d.idLabel, 11) }
        rows.append(r)
        for kid in (children[d.id] ?? []).sorted(by: { $0.name < $1.name }) {
            walk(kid, depth + 1)
        }
    }
    for root in s.attachedDevices.filter({ $0.parentID == nil }).sorted(by: { $0.name < $1.name }) {
        walk(root, 0)
    }
    return rows
}

private func dnsView(_ s: TopologySnapshot, _ st: TUIState,
                     _ f: TUIFrame, _ w: Int) -> [String] {
    guard !s.dnsConfigs.isEmpty else { return ["", "  (no DNS configuration reported)"] }
    var rows: [String] = []
    if let global = s.dnsConfigs.first(where: { $0.isGlobal }) {
        let servers = global.servers.map { maskIfNeeded($0, st.privacy) }.joined(separator: "  ")
        var line = "  Active resolvers: " + paint(servers, .headline, f.colorMode)
        if let ifn = global.interfaceName { line += paint("   via \(ifn)", .dim, f.colorMode) }
        rows.append(line)
        // Search domains get their own clipped row: a VPN can push a dozen of them, which
        // would otherwise run off the screen (auto-wrap is disabled, so it would be
        // truncated by the terminal rather than by us — and shove the layout around).
        if !global.searchDomains.isEmpty {
            let joined = global.searchDomains.joined(separator: " ")
            rows.append(paint("  search: " + clip(joined, max(10, w - 12), unicode: f.unicode),
                              .dim, f.colorMode))
        }
        rows.append("")
    }
    let head = "  " + cell("SCOPE", 24) + cell("IFACE", 9)
        + cell("RESOLVERS", 32) + cell("SEARCH", 20)
    rows.append(paint(cell(head, w, unicode: f.unicode), .dim, f.colorMode))
    for d in s.dnsConfigs where !d.isGlobal {
        var scope = d.scopeLabel
        if st.privacy && d.userNamedScope { scope = "(service)" }
        if d.isPrimary { scope = (f.unicode ? "★ " : "* ") + scope }
        if d.isSupplemental { scope += " [split-DNS]" }
        var r = "  " + cell(scope, 24) + cell(d.interfaceName ?? "—", 9)
        r += cell(d.servers.map { maskIfNeeded($0, st.privacy) }.joined(separator: " "), 32)
        r += cell(d.searchDomains.joined(separator: " "), 20)
        rows.append(r)
    }
    return rows
}

/// The text graph: the product's layered story — what reaches the internet, through which
/// gateway, and whether a tunnel is in the way — as bands + a path, not ASCII wire art.
/// (Reproducing the engine's curves, lanes and encapsulation sheaths in character cells
/// would be a large, low-payoff sub-project; the bands carry the meaning.)
private func graphView(_ s: TopologySnapshot, _ rates: TrafficRateDeriver,
                       _ st: TUIState, _ f: TUIFrame, _ w: Int) -> [String] {
    let m = f.colorMode
    var rows: [String] = []
    let pipe = f.unicode ? "│" : "|"
    let cloud = f.unicode ? "☁" : "@"

    // Internet + egress.
    if let e = s.egress {
        let name = maskIfNeeded(e.displayName, st.privacy)
        rows.append("  " + paint("\(cloud) Internet", .headline, m)
                    + paint("  — via \(e.viaInterface) (\(name))", .dim, m))
    } else {
        rows.append("  " + paint("\(cloud) Internet", .dim, m) + paint("  — no egress", .dim, m))
    }
    rows.append("      " + paint(pipe, .dim, m))

    // Gateway chips, winner first.
    if !s.gateways.isEmpty {
        let sorted = s.gateways.sorted { ($0.precedence ?? 99) < ($1.precedence ?? 99) }
        for g in sorted {
            var line = "  " + paint(cell(g.titleLabel, 12), g.isVPN ? .teal : .amber, m)
            line += cell(maskIfNeeded(g.id, st.privacy), 17)
            if let server = g.vpnServer {
                line += paint("→ \(maskIfNeeded(server, st.privacy))", .teal, m)
                if let carrier = g.vpnCarrier { line += paint("  via \(carrier)", .dim, m) }
            } else if let net = g.networkName {
                line += paint(net, .dim, m)
            }
            rows.append(line)
        }
        rows.append("      " + paint(pipe, .dim, m))
    }

    // The OSI bands, top-down, exactly as the graph stacks them.
    let ifaces = visibleInterfaces(s, st, rates)
    for (layer, osi) in [("Physical", "L1"), ("Data Link", "L2"), ("Virtual", "L2+")] {
        let groups = subgroups(layer: layer, ifaces: ifaces)
        guard !groups.isEmpty else { continue }
        rows.append(rule("\(layer)  (OSI \(osi))", w, f, .dim))
        for group in groups {
            for i in group.interfaces {
                var line = "  " + dot(i.linkState, f) + " "
                line += paint(cell(i.id, 10), color(for: i.category), m)
                line += cell(i.category.rawValue, 13)
                line += cell(maskIfNeeded(i.ipv4Addresses.first ?? "—", st.privacy), 17)
                let rx = formatRateShort(rates.rxRate(for: i.id))
                let tx = formatRateShort(rates.txRate(for: i.id))
                if rx != nil || tx != nil {
                    let arrows = f.unicode ? ("↓", "↑") : ("v", "^")
                    let flow = "\(arrows.0)\(rx ?? "—") \(arrows.1)\(tx ?? "—")"
                    line += paint(flow, .up, m)
                }
                rows.append(line)
            }
        }
    }
    return rows
}

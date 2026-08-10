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

/// Pad (or clip) to exactly `width` cells, always leaving at least one trailing space so a
/// value that exactly fills its column can't run into the next one. (Without the reserve,
/// a 13-cell "Miscellaneous" in a 13-wide CLASS column abutted the VID:PID beside it, and
/// an 11-cell "Thunderbolt" bus produced "ThunderboltT7 Shield 2 TB".)
func cell(_ s: String, _ width: Int, unicode: Bool = true) -> String {
    let t = clip(s, max(0, width - 1), unicode: unicode)
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

/// Colour a fragment.
///
/// Sanitizes here, at the choke point, rather than at each call site. `cell()`/`clip()`
/// already neuter escapes for anything that goes through a column, but the Hardware band
/// composes its lines by concatenating painted fragments directly — so a USB product string
/// or a Bluetooth alias containing `ESC[2J` reached the terminal raw and let an attached
/// device erase and repaint the operator's screen. Every caller passes plain text, so
/// sanitizing the input here closes that class of bug for good instead of one site at a time.
func paint(_ s: String, _ c: TUIColor, _ mode: TUIColorMode) -> String {
    let s = sanitizeForTerminal(s)
    switch mode {
    case .none:     return s
    case .ansi16:   return "\u{1B}[\(c.ansi16)m\(s)\u{1B}[0m"
    case .xterm256: return "\u{1B}[38;5;\(c.xterm)m\(s)\u{1B}[0m"
    }
}

/// Reverse video — used for the active tab and section rules so the UI still parses with
/// colour disabled, which is what makes the no-colour tier genuinely usable.
func reverse(_ s: String, _ mode: TUIColorMode) -> String {
    let s = sanitizeForTerminal(s)
    return mode == .none ? "[\(s)]" : "\u{1B}[7m\(s)\u{1B}[27m"
}

func bold(_ s: String, _ mode: TUIColorMode) -> String {
    let s = sanitizeForTerminal(s)
    return mode == .none ? s : "\u{1B}[1m\(s)\u{1B}[22m"
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

/// Forwards to the shared masker in PrivacyMask.swift. This was a second, divergent
/// implementation: it had no IPv6 branch (so `fe80::…` passed through in the clear) and it
/// masked netmasks, which the GUI deliberately leaves legible.
func maskIfNeeded(_ s: String, _ on: Bool) -> String { maskAddresses(s, on) }

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
        // The network NAME is the SSID (or the wired search domain) — it names a home or an
        // office, so privacy mode replaces it outright rather than masking octets. The
        // address masker never touched it, since an SSID isn't address-shaped.
        bits.append("egress \(e.viaInterface) (\(maskNetworkName(e.displayName, st.privacy)))")
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

/// Link-state glyph. Up and down MUST use different characters, not just different colours:
/// `--no-color`, `NO_COLOR`, `TERM=dumb` and `--once` into a pipe are all first-class, and
/// with colour off a filled dot for both made the single most important per-interface fact
/// unreadable — `netlights tui --once > report.txt` showed a dead port and a live one alike.
private func dot(_ ls: LinkState, _ f: TUIFrame) -> String {
    switch ls {
    case .up:      return paint(f.unicode ? "●" : "*", .up, f.colorMode)
    case .down:    return paint(f.unicode ? "✕" : "x", .down, f.colorMode)
    case .unknown: return paint(f.unicode ? "○" : "o", .unknown, f.colorMode)
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
    // DESCRIPTION gets its own (lower) threshold ahead of MAC: knowing that en5 is "USB LAN"
    // is more diagnostic than its MAC, and pinning both to 132 meant an 80- or 100-column
    // terminal could not identify an adapter anywhere in the TUI.
    let wide = w >= 132, mid = w >= 104, named = w >= 92
    var head = "  " + cell("IFACE", 10) + cell("TYPE", 13)
    if named { head += cell("DESCRIPTION", 19) }
    head += cell("IPV4", 16)
    if mid  { head += cell("MAC", 18) }
    head += cell("SPEED", 10) + cell("RX/s", 11) + cell("TX/s", 11)
    if wide { head += cell("RX", 10) + cell("TX", 10) }
    var rows = [paint(cell(head, w, unicode: f.unicode), .dim, f.colorMode)]

    // An interface provided by a USB adapter should read as that adapter, so the Interfaces
    // and Devices tabs refer to each other.
    let providedBy = Dictionary(
        s.attachedDevices.compactMap { d in d.interfaceBSD.map { ($0, d.name) } },
        uniquingKeysWith: { a, _ in a })

    let egressIface = s.egress?.viaInterface
    for i in visibleInterfaces(s, st, rates) {
        var r = dot(i.linkState, f) + " "
        // Star the interface that actually reaches the internet — the header names it, but
        // the table gave no way to spot it among several that are up.
        let star = i.id == egressIface ? (f.unicode ? "★" : "*") : " "
        r += paint(cell(star + i.id, 10), color(for: i.category), f.colorMode)
        r += cell(i.category.rawValue, 13)
        // Prefer the adapter that provides the interface, then the SystemConfiguration
        // hardware-port name ("Wi-Fi", "Thunderbolt 1"), matching the macOS Interfaces tab,
        // and fall back to subtitleLabel for interfaces SC doesn't name. Not subtitleLabel
        // first: it substitutes the IP address, which is right for a graph node but
        // duplicates the IPV4 column here.
        if named {
            let desc = providedBy[i.id] ?? i.displayName ?? i.subtitleLabel
            r += cell(maskIfNeeded(desc, st.privacy), 19)
        }
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
    // IFACE is 10, not 9: the trailing-separator reserve in cell() costs one cell, and at 9
    // both bridge100 and bridge101 truncated to the same "bridge1…" on any Mac running
    // Internet Sharing or a VM bridge.
    let head = "  " + cell("DESTINATION", 20) + cell("GATEWAY", 17)
        + cell("NETMASK", 17) + cell("IFACE", 10) + cell("FLAGS", 8) + cell("PRIO", 6)
    var rows: [String] = []
    let primaryID = primaryDefaultRouteID(s.routes, egress: s.egress)

    func emit(_ list: [RouteEntry]) {
        for r in list.sorted(by: { routeSortKey($0.destination) < routeSortKey($1.destination) }) {
            var line = "  "
            // Only the winning default is starred — see primaryDefaultRouteID.
            let dest = r.id == primaryID ? "\(r.destination) \(f.unicode ? "✦" : "*")" : r.destination
            line += cell(maskIfNeeded(dest, st.privacy), 20)
            line += cell(maskIfNeeded(r.gateway.isEmpty ? "—" : r.gateway, st.privacy), 17)
            // Netmask is NOT masked — it describes the prefix, not the host, and the GUI
            // leaves it legible too. Masking it turned 255.255.255.0 into "255.x.x.x".
            line += cell(r.netmask ?? "—", 17)
            line += cell(r.interfaceName, 10) + cell(r.flags, 8)
            // Linux route metric, else the macOS network-service rank. Lower wins on both;
            // they are mutually exclusive by platform, so one column serves both.
            line += cell(r.metric.map(String.init)
                         ?? s.serviceRank[r.interfaceName].map { "\($0 + 1)" } ?? "—", 6)
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
        return ["", "  No external devices detected.",
                "  USB peripherals, hubs/docks and external displays appear here when connected."]
    }
    // Columns are added by priority while the DEVICE column can still hold a useful name,
    // and DEVICE then takes everything left over. It used to be pinned at 30 cells at EVERY
    // terminal size — so "CORSAIR K65 PLUS WIRELESS Keyboard" was clipped on an 80-column
    // terminal and equally clipped on a 200-column one, where 90 columns sat empty. TYPE and
    // CLASS are 16 because the longest labels ("Game Controller", "Vendor-Specific") are 15.
    let optional: [(String, Int)] = [("VENDOR", 16), ("BUS", 11), ("PORT", 14),
                                     ("CLASS", 16), ("VID:PID", 11)]
    let minName = 24
    var cols: [(String, Int)] = [("TYPE", 16), ("SPEED", 15)]
    // -1: the header is run through cell(head, w), which reserves a trailing separator cell.
    var used = 2 + cols.reduce(0) { $0 + $1.1 } + 1
    for col in optional where used + col.1 + minName <= w {
        cols.append(col); used += col.1
    }
    // Keep the on-screen order stable regardless of which ones fitted.
    let order = ["TYPE", "VENDOR", "BUS", "SPEED", "PORT", "CLASS", "VID:PID"]
    cols.sort { order.firstIndex(of: $0.0)! < order.firstIndex(of: $1.0)! }
    let shown = Set(cols.map(\.0))
    let nameW = max(minName, w - used)

    var head = "  " + cell("DEVICE", nameW)
    for (title, width) in cols { head += cell(title, width) }
    var rows = [paint(cell(head, w, unicode: f.unicode), .dim, f.colorMode)]

    // Pre-order walk so hubs own their children, mirroring the graph's device tree. A
    // parentID naming a device that isn't in the snapshot must fall back to being a root,
    // or the device is neither a root nor reachable and silently vanishes from the table
    // while the header still counts it. Both the GUI and the layout engine guard this.
    let byId = Dictionary(s.attachedDevices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let children = Dictionary(grouping: s.attachedDevices.filter {
        guard let pid = $0.parentID else { return false }
        return byId[pid] != nil
    }, by: { $0.parentID! })
    func byName(_ a: AttachedDevice, _ b: AttachedDevice) -> Bool {
        a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
    func walk(_ d: AttachedDevice, _ depth: Int) {
        let indent = String(repeating: "  ", count: min(depth, 8))
        // A USB-Ethernet dongle or MiFi OWNS an interface; without this the device table and
        // the interface table never referred to each other.
        let name = indent + maskIfNeeded(d.name, st.privacy)
            + (d.interfaceBSD.map { " \(f.unicode ? "→" : "->") \($0)" } ?? "")
        let value: [String: String] = [
            "TYPE": d.kind.label,
            "VENDOR": d.vendorName ?? "—",
            "BUS": d.connectionLabel,
            "SPEED": d.speedLabel,
            "PORT": devicePortLabel(d, s.hardwarePorts),
            "CLASS": d.classLabel,
            "VID:PID": d.idLabel,
        ]
        var r = "  " + cell(name, nameW)
        for (title, width) in cols where shown.contains(title) {
            r += cell(value[title] ?? "—", width)
        }
        rows.append(r)
        for kid in (children[d.id] ?? []).sorted(by: byName) { walk(kid, depth + 1) }
    }
    // Group by the port a device is plugged into, then by name — so the table reads
    // port-by-port like the graph, instead of interleaving receptacles alphabetically.
    let roots = s.attachedDevices.filter { $0.parentID == nil || byId[$0.parentID!] == nil }
    for root in roots.sorted(by: {
        $0.receptacle != $1.receptacle ? $0.receptacle < $1.receptacle : byName($0, $1)
    }) {
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
            let joined = maskDomainList(global.searchDomains, st.privacy, separator: " ")
            rows.append(paint("  search: " + clip(joined, max(10, w - 12), unicode: f.unicode),
                              .dim, f.colorMode))
        }
        rows.append("")
    }
    let head = "  " + cell("SCOPE", 24) + cell("IFACE", 10)
        + cell("RESOLVERS", 32) + cell("SEARCH", 20)
    rows.append(paint(cell(head, w, unicode: f.unicode), .dim, f.colorMode))
    for d in s.dnsConfigs where !d.isGlobal {
        var scope = maskScopeLabel(d.scopeLabel, interfaceName: d.interfaceName,
                                   userNamed: d.userNamedScope, st.privacy)
        if d.isPrimary { scope = (f.unicode ? "★ " : "* ") + scope }
        if d.isSupplemental { scope += " [split-DNS]" }
        var r = "  " + cell(scope, 24) + cell(d.interfaceName ?? "—", 10)
        r += cell(d.servers.map { maskIfNeeded($0, st.privacy) }.joined(separator: " "), 32)
        // Search / split-DNS domains name the employer, which is exactly what the help text
        // promises privacy mode redacts.
        r += cell(maskDomainList(d.searchDomains, st.privacy, separator: " "), 20)
        rows.append(r)
    }
    return rows
}

/// The Hardware (OSI L0) band for the text graph: one row per receptacle or synthetic
/// entity, with the interfaces it carries and the device tree hanging off it — the same
/// slot order the SwiftUI/SVG graph lays out left-to-right (iPhone, TB ports, Wi-Fi,
/// Displays, Bluetooth, Battery), read top-to-bottom instead.
private func hardwareBand(_ s: TopologySnapshot, _ st: TUIState, _ rates: TrafficRateDeriver,
                          _ f: TUIFrame, _ w: Int) -> [String] {
    let m = f.colorMode
    let visible = visibleInterfaces(s, st, rates)
    let displays = s.attachedDevices.filter { $0.receptacle == -2 }
    let bluetooth = s.attachedDevices.filter { $0.receptacle == -4 }
    // The SAME rule the graph uses: Wi-Fi counts as hardware to draw only when it is an
    // actual uplink. Testing for a Wi-Fi interface's mere existence kept a "Wi-Fi" slot on
    // screen after the radio was switched off, while the graph correctly dropped it.
    let wifiUp = wifiUplink(gateways: s.gateways, interfaces: s.interfaces)
    guard !s.hardwarePorts.isEmpty || !s.attachedDevices.isEmpty
            || wifiUp != nil || s.systemPower != nil else { return [] }

    var rows = [rule("Hardware  (OSI L0)", w, f, .dim)]
    let arrow = f.unicode ? "→" : "->"
    let tee = f.unicode ? "├─" : "|-"      // a child with siblings below it
    let elbow = f.unicode ? "└─" : "`-"    // the last child

    // Same dangling-parent guard as the Devices table: a child whose parent isn't in the
    // snapshot must still appear, as a root on its own receptacle.
    let byId = Dictionary(s.attachedDevices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let children = Dictionary(grouping: s.attachedDevices.filter {
        guard let pid = $0.parentID else { return false }
        return byId[pid] != nil
    }, by: { $0.parentID! })
    func byKindThenName(_ a: AttachedDevice, _ b: AttachedDevice) -> Bool {
        a.kind.label != b.kind.label ? a.kind.label < b.kind.label
            : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    func emitDevice(_ d: AttachedDevice, _ depth: Int, last: Bool) {
        let pad = String(repeating: "  ", count: min(depth, 6))
        var line = "      " + pad + paint((last ? elbow : tee) + " ", .dim, m)
        line += paint(maskIfNeeded(d.name, st.privacy), .headline, m)
        var tail: [String] = [d.kind.label]
        if let bsd = d.interfaceBSD { tail.append("\(arrow) \(bsd)") }
        if d.speedLabel != "—" { tail.append(d.speedLabel) }
        if let b = d.batteryLabel { tail.append(b) }
        line += paint("  " + tail.joined(separator: " · "), .dim, m)
        rows.append(line)
        let kids = (children[d.id] ?? []).sorted(by: byKindThenName)
        for (n, kid) in kids.enumerated() { emitDevice(kid, depth + 1, last: n == kids.count - 1) }
    }

    /// One slot header plus everything hanging off it.
    // `tint`, not `color` — a parameter named `color` would shadow the `color(for:)`
    // category-palette function used two lines down.
    func emitSlot(_ title: String, _ tint: TUIColor, subtitle: String,
                  bsds: [String], devices: [AttachedDevice]) {
        var head = "  " + paint(cell(title, 30), tint, m)
        if !subtitle.isEmpty { head += paint(subtitle, .dim, m) }
        rows.append(head)
        // The interfaces this receptacle carries — the "physical adapter" relation the
        // Physical band alone can't express.
        for bsd in bsds.sorted() {
            // Honour "hide inactive" here too. The band looked interfaces up directly, so a
            // down interface stayed listed under its port while the same interface was
            // hidden everywhere else on screen.
            guard let i = visible.first(where: { $0.id == bsd }) else { continue }
            var line = "      " + dot(i.linkState, f) + " "
            line += paint(cell(i.id, 10), color(for: i.category), m)
            line += paint(cell(i.category.rawValue, 13), .dim, m)
            line += paint(maskIfNeeded(i.ipv4Addresses.first ?? "—", st.privacy), .dim, m)
            rows.append(line)
        }
        let roots = devices.sorted(by: byKindThenName)
        for (n, d) in roots.enumerated() { emitDevice(d, 0, last: n == roots.count - 1) }
    }

    // Real receptacles: the iPhone/iPad entry first (it's the one most likely to be the
    // egress), then TB ports in order — matching hwPortOrder in the layout engine.
    let phone = s.hardwarePorts.filter(\.isPhone)
    let tb = s.hardwarePorts.filter { !$0.isPhone }.sorted { $0.id < $1.id }
    for p in phone + tb {
        var bsds = Set(p.childBSDNames)
        for d in s.attachedDevices where d.receptacle == p.id {
            if let bsd = d.interfaceBSD { bsds.insert(bsd) }
        }
        let roots = s.attachedDevices.filter {
            $0.receptacle == p.id && ($0.parentID == nil || byId[$0.parentID!] == nil)
        }
        // A bare, empty port is noise; skip it unless something is actually attached.
        guard !bsds.isEmpty || !roots.isEmpty || p.hasConnectedDevice || p.hasPower else { continue }
        var badges: [String] = []
        if p.hasPower { badges.append(f.unicode ? "⚡︎ charger" : "charger") }
        emitSlot(hardwarePortLabel(p), .purple,
                 subtitle: badges.joined(separator: " · "),
                 bsds: Array(bsds), devices: roots)
    }

    // Synthetic entities — the same ones the graph draws as Hardware-row cards.
    if let wifi = wifiUp {
        let wifiBSDs = [wifi]
        // Only label the slot with the network name when Wi-Fi is actually the uplink. Taking
        // it from the egress unconditionally printed "Wi-Fi / Wired" on a docked laptop —
        // reading as if the machine were associated to a network called "Wired", and
        // disagreeing with the SwiftUI/SVG graph, which draws no Wi-Fi entity at all there.
        let ssid = s.egress.flatMap { e in
            wifiBSDs.contains(e.viaInterface) ? maskNetworkName(e.displayName, st.privacy) : nil
        } ?? ""
        emitSlot("Wi-Fi", .wifi, subtitle: ssid, bsds: wifiBSDs, devices: [])
    }
    if !displays.isEmpty {
        emitSlot("Displays", .headline, subtitle: "\(displays.count) external",
                 bsds: [], devices: displays)
    }
    if !bluetooth.isEmpty {
        emitSlot("Bluetooth", .wifi, subtitle: "\(bluetooth.count) connected",
                 bsds: [], devices: bluetooth)
    }
    if let label = s.systemPower?.label {
        rows.append("  " + paint(cell("Battery", 30), .amber, m) + paint(label, .dim, m))
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
        let name = maskNetworkName(e.displayName, st.privacy)
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
                line += paint(maskNetworkName(net, st.privacy), .dim, m)
            }
            rows.append(line)
        }
        rows.append("      " + paint(pipe, .dim, m))
    }

    // Hardware (OSI L0) — the band the text graph used to omit entirely. Without it the
    // TUI never showed which receptacle anything is plugged into, never nested a device
    // under its hub, and never showed that en0 hangs off the Wi-Fi radio: the graph said
    // "12 dev" in the header and then listed none of them.
    rows.append(contentsOf: hardwareBand(s, st, rates, f, w))

    // The OSI bands, top-down, exactly as the graph stacks them.
    let ifaces = visibleInterfaces(s, st, rates)
    for (layer, osi) in [("Physical", "L1"), ("Data Link", "L2"), ("Virtual", "L2+")] {
        let groups = subgroups(layer: layer, ifaces: ifaces)
        guard !groups.isEmpty else { continue }
        rows.append(rule("\(layer)  (OSI \(osi))", w, f, .dim))
        for group in groups {
            // `subgroups` already computes the group label ("VPN / Tunnels", "Apple
            // Wireless", …) and the SwiftUI graph draws it; the TUI was computing it and
            // throwing it away, so the band read as one undifferentiated list.
            if groups.count > 1 && !group.label.isEmpty {
                rows.append(paint("    " + group.label, .dim, m))
            }
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

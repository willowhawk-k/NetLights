import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Server-side SVG renderer for the graph — the web/Linux analog of NetworkGraphView.
// It lives in Core so it has INTERNAL access to the GraphLayoutEngine geometry and the
// model types (so only ONE public entry point is needed, not a mass public-ification).
// The macOS app keeps using its SwiftUI renderer; this drives the web UI.
//
// The rule this file has to hold to: the layout engine decides WHERE things go and how much
// room they need, so the renderer must draw every node the engine positions, at the size the
// engine budgeted. Breaking either half shows up immediately as a wire that ends in empty
// space (a node the engine placed but nothing drew) or as overlapping labels (text drawn
// wider than the box the engine reserved).

/// Render a snapshot to a standalone SVG string, reusing the shared layout engine so the
/// OSI-band geometry is identical to the macOS graph. A fresh engine + cache per call
/// (one-shot per HTTP request).
///
/// `width`/`height` are the browser's viewport, forwarded from `?w=&h=` — the equivalent of
/// the GeometryReader the SwiftUI graph re-lays-out from on every window resize. They used
/// to be hard-coded at 1200×760, which froze every width-dependent decision (row wrapping,
/// hardware-slot compression, per-node width) at a size nobody was actually viewing.
public func renderGraphSVG(snapshot: TopologySnapshot,
                           width: Double = 1200, height: Double = 760,
                           privacy: Bool = false, hideUnused: Bool = false,
                           trafficStates: [String: TrafficState] = [:]) -> String {
    let engine = GraphLayoutEngine(
        interfaces: snapshot.interfaces,
        trafficStates: trafficStates,
        routes: snapshot.routes,
        gateways: snapshot.gateways,
        hardwarePorts: snapshot.hardwarePorts,
        attachedDevices: snapshot.attachedDevices,
        egress: snapshot.egress,
        systemPower: snapshot.systemPower,
        hideUnused: hideUnused,
        viewSize: CGSize(width: width, height: height),
        cache: LayoutCache())
    return engine.svgString(privacy: privacy)
}

extension GraphLayoutEngine {
    func svgString(privacy: Bool) -> String {
        let W = Double(bw), H = Double(bh)
        var o = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 \(num(W)) \(num(H))' "
              + "width='\(num(W))' height='\(num(H))' font-family='ui-monospace,SFMono-Regular,Menlo,monospace'>"
        o += "<rect x='0' y='0' width='\(num(W))' height='\(num(H))' fill='#0d1117'/>"

        // OSI bands (background tints, a hairline border, and a caption). The caption sits
        // at the BOTTOM of the band, as in the SwiftUI graph — at the top it collided with
        // the first row of nodes (0.8px of clearance in the Virtual band).
        for band in bands {
            let r = bandRect(band.id)
            let y = Double(r.minY), h = Double(r.height)
            o += "<rect x='0' y='\(num(y))' width='\(num(W))' height='\(num(h))' fill='\(band.color.css)'/>"
            o += "<rect x='0.5' y='\(num(y + 0.5))' width='\(num(W - 1))' height='\(num(h - 1))' "
               + "fill='none' stroke='#21262d' stroke-width='1'/>"
            o += "<text x='12' y='\(num(y + h - 8))' fill='#8b949e' font-size='11' font-weight='600'>\(xmlEsc(band.name))</text>"
            o += "<text x='\(num(W - 12))' y='\(num(y + h - 8))' fill='#586069' font-size='10' text-anchor='end'>OSI \(xmlEsc(band.osiLabel))</text>"
        }

        // Connection wires (quadratic curves, same control points as the macOS graph).
        for line in buildLines() {
            let c = curveControl(line)
            let d = "M \(num(Double(line.from.x))) \(num(Double(line.from.y))) "
                  + "Q \(num(Double(c.x))) \(num(Double(c.y))) \(num(Double(line.to.x))) \(num(Double(line.to.y)))"
            let col = line.color.css
            // `class='wire'` + the carried interface let the browser toggle the ant-crawl
            // animation on wires whose interface has live traffic.
            let wire = "class='wire'" + (line.ifaceID.map { " data-iface='\(xmlEsc($0))'" } ?? "")
            if line.encapsulated {   // VPN tunnel: soft glow underlay + animatable dashed core
                o += "<path d='\(d)' fill='none' stroke='\(col)' stroke-width='7' stroke-opacity='0.18'/>"
                o += "<path \(wire) d='\(d)' fill='none' stroke='\(col)' stroke-width='2.5' stroke-opacity='0.9' stroke-dasharray='7 5'/>"
            } else {
                let dash = line.style == .data ? " stroke-dasharray='5 5'" : ""
                o += "<path \(wire) d='\(d)' fill='none' stroke='\(col)' stroke-width='\(line.dominant ? "2.4" : "1.4")' stroke-opacity='0.8'\(dash)/>"
            }
        }

        // Thunderbolt port brackets — the engine computes the span and label; the SVG used
        // to drop them, so a port owning several interfaces lost the visual grouping.
        for b in tbBracketSpans() {
            let y = Double(b.y)
            o += "<path d='M \(num(Double(b.minX))) \(num(y + 6)) V \(num(y)) H \(num(Double(b.maxX))) V \(num(y + 6))' "
               + "fill='none' stroke='#6e7681' stroke-opacity='0.5' stroke-width='1'/>"
            o += label((Double(b.minX) + Double(b.maxX)) / 2, y - 4, b.label, 8, "#8b949e")
        }

        // Nodes.
        for iface in visible {
            if let p = ifacePositions[iface.id] { o += ifaceNode(p, iface, privacy: privacy) }
        }
        for port in hardwarePorts {
            if let p = hwPortPositions[port.id] { o += portNode(p, port) }
        }
        // The four SYNTHETIC hardware-row entities. The engine allocates a slot for each
        // (hwPortOrder uses negative sentinel keys) and routes wires into it, but this
        // renderer only ever iterated the real `hardwarePorts` — so en0's uplink and every
        // display/Bluetooth chip's attachment wire terminated on blank canvas.
        o += entitySlots(privacy: privacy)

        for dev in attachedDevices {
            if let p = devicePositions[dev.id] { o += deviceNode(p, dev, privacy: privacy) }
        }
        for gw in gateways {
            if let p = gatewayPositions[gw.id] { o += gwNode(p, gw, privacy: privacy) }
        }
        if let e = egress, let p = egressPosition {
            o += egressNode(p, via: e.viaInterface,
                            name: maskNetworkName(e.displayName, privacy))
        }
        if let sid = vpnServerID, let p = vpnServerPosition {
            let box = GraphNodeSize.vpnServer
            o += svgNode(p, box.w, box.h, stroke: ColorToken.gatewayVPN.css,
                         title: "VPN Server", subtitle: maskAddresses(sid, privacy), full: sid)
        }
        if hasVPNExcludes, let p = vpnExcludePosition {
            let box = GraphNodeSize.vpnExclude
            o += svgNode(p, box.w, box.h, stroke: ColorToken.split.css,
                         title: "Direct", subtitle: "\(vpnExcludeRoutes.count) excluded", full: nil)
        }

        o += "</svg>"
        return o
    }

    /// Wi-Fi (-1), Displays (-2), Battery (-3) and Bluetooth (-4) — drawn only when the
    /// engine actually reserved the slot, so the set matches the wires it emitted.
    private func entitySlots(privacy: Bool) -> String {
        var o = ""
        if let p = hwPortPositions[-1] {
            let ssid = egress.map { maskNetworkName($0.displayName, privacy) } ?? "network"
            o += entityNode(p, title: "Wi-Fi", subtitle: ssid, stroke: "#58a6ff") { x, y, c in
                categoryIcon(.wifi, x, y, c)
            }
        }
        if let p = hwPortPositions[-2] {
            let n = attachedDevices.filter { $0.receptacle == -2 }.count
            o += entityNode(p, title: "Displays", subtitle: "\(n) external", stroke: "#39c5cf") { x, y, c in
                let st = iconStroke(c)
                return "<g transform='translate(\(num(x)),\(num(y)))'>"
                     + "<rect x='-7' y='-5' width='11' height='8' rx='1.5' \(st)/>"
                     + "<rect x='-3' y='-2' width='11' height='8' rx='1.5' \(st)/></g>"
            }
        }
        if let p = hwPortPositions[-4] {
            let n = attachedDevices.filter { $0.receptacle == -4 }.count
            o += entityNode(p, title: "Bluetooth", subtitle: "\(n) connected", stroke: "#58a6ff") { x, y, c in
                let st = iconStroke(c)
                return "<g transform='translate(\(num(x)),\(num(y)))'>"
                     + "<path d='M -1 5 A 5 5 0 0 0 -1 -5' \(st)/>"
                     + "<path d='M 2 7 A 8 8 0 0 0 2 -7' \(st)/></g>"
            }
        }
        if let p = hwPortPositions[-3], let power = systemPower {
            let pct = power.level.map { "\($0)%" } ?? "Power"
            o += entityNode(p, title: pct, subtitle: power.stateLabel, stroke: "#f0883e") { x, y, c in
                let st = iconStroke(c)
                return "<g transform='translate(\(num(x)),\(num(y)))'>"
                     + "<rect x='-8' y='-4' width='14' height='8' rx='1.5' \(st)/>"
                     + "<path d='M 7 -1.5 v 3' \(st)/></g>"
            }
        }
        return o
    }
}

private func iconStroke(_ c: String) -> String {
    "stroke='\(c)' stroke-width='1.3' fill='none' stroke-linecap='round'"
}

// MARK: - Node primitives

/// A rounded-rect node with a title + optional subtitle, centered on `p`. `full` supplies a
/// `<title>` child so a truncated label still has its complete text on hover — the SVG had
/// no hover affordance at all, so a clipped name was simply unreadable.
private func svgNode(_ p: CGPoint, _ w: Double, _ h: Double, stroke: String,
                     title: String, subtitle: String, full: String?) -> String {
    let cx = Double(p.x), cy = Double(p.y)
    var s = "<g>"
    if let full, !full.isEmpty { s += "<title>\(xmlEsc(full))</title>" }
    s += "<rect x='\(num(cx - w / 2))' y='\(num(cy - h / 2))' width='\(num(w))' height='\(num(h))' rx='7' "
       + "fill='#161b22' stroke='\(stroke)' stroke-opacity='0.75'/>"
    s += label(cx, cy - 1, fit(title, w), 11, "#e6edf3")
    if !subtitle.isEmpty {
        s += label(cx, cy + 11, fit(subtitle, w, size: 8), 8, "#8b949e")
    }
    s += "</g>"
    return s
}

private func card(_ cx: Double, _ cy: Double, _ w: Double, _ h: Double, _ border: String) -> String {
    "<rect x='\(num(cx - w / 2))' y='\(num(cy - h / 2))' width='\(num(w))' height='\(num(h))' rx='8' fill='#161b22' stroke='\(border)' stroke-opacity='0.65'/>"
}

private func label(_ cx: Double, _ y: Double, _ text: String, _ size: Double, _ color: String) -> String {
    "<text x='\(num(cx))' y='\(num(y))' fill='\(color)' font-size='\(num(size))' text-anchor='middle'>\(xmlEsc(text))</text>"
}

/// Clip a label to what actually fits the box. SVG `<text>` does not wrap, clip or ellipsize
/// on its own — it just keeps drawing — so the renderer has to budget characters itself.
/// The stack is monospace, where the advance is ~0.6em, and 5px of padding is left on each
/// side to match the SwiftUI chips.
private func fit(_ s: String, _ boxW: Double, size: Double = 11) -> String {
    let usable = max(boxW - 10, 8)
    let budget = max(2, Int(usable / (size * 0.6)))
    guard s.count > budget else { return s }
    return String(s.prefix(budget - 1)) + "…"
}

// MARK: - Typed nodes

private func portNode(_ p: CGPoint, _ port: HardwarePort) -> String {
    let box = GraphNodeSize.port
    let cx = Double(p.x), cy = Double(p.y)
    // A tethered iPhone/iPad is a hardware port too; rendering it as "TB 0" erased its
    // identity. Titles now come from the same helper the SwiftUI brackets use.
    let title = port.isPhone ? port.deviceName : "TB \(port.id)"
    let location = port.position.isEmpty ? port.side : "\(port.side) · \(port.position)"
    let subtitle = port.isPhone ? port.connectionMedium : location
    var s = "<g><title>\(xmlEsc(hardwarePortLabel(port)))</title>"
    s += card(cx, cy, box.w, box.h, port.hasConnectedDevice ? "#3fb950" : "#6e7681")
    let led = port.hasConnectedDevice ? "#3fb950" : "#6e7681"
    s += "<circle cx='\(num(cx + box.w / 2 - 9))' cy='\(num(cy - box.h / 2 + 9))' r='3.5' fill='\(led)'/>"
    // Yellow plug badge for a USB-C charger, matching HardwarePortNodeView.
    if port.hasPower {
        s += "<g transform='translate(\(num(cx - box.w / 2 + 10)),\(num(cy - box.h / 2 + 9)))'>"
           + "<rect x='-3.5' y='-2' width='7' height='5' rx='1' fill='none' stroke='#e3b341' stroke-width='1.2'/>"
           + "<path d='M -2 -2 v -2.5 M 2 -2 v -2.5' stroke='#e3b341' stroke-width='1.2' stroke-linecap='round'/></g>"
    }
    s += label(cx, cy + 6, fit(title, box.w), 11, "#e6edf3")
    if !subtitle.isEmpty { s += label(cx, cy + 19, fit(subtitle, box.w, size: 8), 8, "#8b949e") }
    s += "</g>"
    return s
}

private func entityNode(_ p: CGPoint, title: String, subtitle: String, stroke: String,
                        icon: (Double, Double, String) -> String) -> String {
    let box = GraphNodeSize.entity
    let cx = Double(p.x), cy = Double(p.y)
    var s = "<g><title>\(xmlEsc(subtitle.isEmpty ? title : "\(title) — \(subtitle)"))</title>"
    s += card(cx, cy, box.w, box.h, stroke)
    s += icon(cx, cy - box.h / 2 + 17, stroke)
    s += label(cx, cy + 10, fit(title, box.w), 11, "#e6edf3")
    if !subtitle.isEmpty { s += label(cx, cy + 22, fit(subtitle, box.w, size: 8), 8, "#8b949e") }
    s += "</g>"
    return s
}

private func deviceNode(_ p: CGPoint, _ dev: AttachedDevice, privacy: Bool) -> String {
    let box = GraphNodeSize.device
    let cx = Double(p.x), cy = Double(p.y)
    // Bluetooth chips are tinted blue to match the Bluetooth entity, as DeviceNodeView does;
    // this renderer painted every chip cyan.
    let tint = dev.connection == "Bluetooth" ? "#58a6ff" : "#39c5cf"
    let name = maskAddresses(dev.name, privacy)
    let subtitle = dev.batteryLabel.map { "\(dev.kind.label) · \($0)" } ?? dev.kind.label
    var s = "<g><title>\(xmlEsc(name))\(dev.interfaceBSD.map { " → \($0)" } ?? "")</title>"
    s += card(cx, cy, box.w, box.h, tint)
    s += deviceIcon(dev.kind, cx, cy - box.h / 2 + 14, tint)
    // deviceShortName is the SwiftUI chip's own rule, so both graphs truncate identically.
    s += label(cx, cy + 8, fit(deviceShortName(name), box.w, size: 8), 8, "#e6edf3")
    s += label(cx, cy + 19, fit(subtitle, box.w, size: 7), 7, "#8b949e")
    s += "</g>"
    return s
}

private func ifaceNode(_ p: CGPoint, _ iface: InterfaceInfo, privacy: Bool) -> String {
    let box = GraphNodeSize.iface
    let cx = Double(p.x), cy = Double(p.y)
    let color = categoryColor(iface.category)
    var s = "<g><title>\(xmlEsc(iface.id))\(iface.displayName.map { " — \($0)" } ?? "")</title>"
    s += card(cx, cy, box.w, box.h, color)
    s += categoryIcon(iface.category, cx, cy - box.h / 2 + 20, color)
    let led = iface.hasLink ? "#3fb950" : (iface.linkState == .down ? "#f85149" : "#6e7681")
    s += "<circle cx='\(num(cx + box.w / 2 - 9))' cy='\(num(cy - box.h / 2 + 9))' r='3.5' fill='\(led)'/>"
    s += label(cx, cy + 10, iface.id, 11, "#e6edf3")
    let sub = maskAddresses(iface.ipv4Addresses.first ?? iface.category.rawValue, privacy)
    s += label(cx, cy + 23, fit(sub, box.w, size: 8), 8, "#8b949e")
    if let speed = iface.formattedSpeed {
        s += label(cx, cy + 35, fit(speed, box.w, size: 7), 7, "#6e7681")
    }
    s += "</g>"
    return s
}

private func gwNode(_ p: CGPoint, _ gw: GatewayNode, privacy: Bool) -> String {
    let box = gw.networkName == nil ? GraphNodeSize.gateway : GraphNodeSize.gatewayNamed
    let cx = Double(p.x), cy = Double(p.y)
    let color = (gw.isVPN ? ColorToken.gatewayVPN : ColorToken.gatewayPrimary).css
    var s = "<g><title>\(xmlEsc(gw.titleLabel)) \(xmlEsc(maskAddresses(gw.id, privacy)))</title>"
    s += card(cx, cy, box.w, box.h, color)
    let iy = cy - box.h / 2 + 14
    s += "<path d='M \(num(cx)) \(num(iy - 5)) L \(num(cx + 5)) \(num(iy)) L \(num(cx)) \(num(iy + 5)) L \(num(cx - 5)) \(num(iy)) Z' "
       + "fill='\(gw.isDefault ? color : "none")' stroke='\(color)' stroke-width='1.3'/>"
    s += label(cx, cy + 6, fit(gw.titleLabel, box.w), 11, "#e6edf3")
    s += label(cx, cy + 18, fit(maskAddresses(gw.id, privacy), box.w, size: 8), 8, "#8b949e")
    if let net = gw.networkName {
        s += label(cx, cy + 30, fit(maskNetworkName(net, privacy), box.w, size: 8), 8, "#6e7681")
    }
    s += "</g>"
    return s
}

private func egressNode(_ p: CGPoint, via: String, name: String) -> String {
    let box = GraphNodeSize.egress
    let cx = Double(p.x), cy = Double(p.y)
    let color = ColorToken.egress.css
    var s = "<g><title>Internet — via \(xmlEsc(via))</title>"
    s += card(cx, cy, box.w, box.h, color)
    let iy = cy - box.h / 2 + 16
    let st = "stroke='\(color)' stroke-width='1.2' fill='none'"
    s += "<g transform='translate(\(num(cx)),\(num(iy)))'><circle r='6' \(st)/><ellipse rx='2.6' ry='6' \(st)/>"
       + "<path d='M -6 0 h 12 M -5 -3 h 10 M -5 3 h 10' \(st)/></g>"
    s += label(cx, cy + 10, "Internet", 11, "#e6edf3")
    s += label(cx, cy + 22, fit(via, box.w, size: 8), 8, "#8b949e")
    s += "</g>"
    return s
}

private func categoryColor(_ c: InterfaceCategory) -> String {
    switch c {
    case .wifi:        return "#58a6ff"
    case .ethernet:    return "#3fb950"
    case .thunderbolt: return "#a371f7"
    case .tunnel:      return "#d29922"
    case .bridge:      return "#db61a2"
    case .vlan:        return "#a371f7"
    case .cellular:    return "#f0883e"
    case .loopback:    return "#6e7681"
    default:           return "#8b949e"
    }
}

/// A small (~12px) line-drawn icon for the category, centered at (x, y).
private func categoryIcon(_ c: InterfaceCategory, _ x: Double, _ y: Double, _ col: String) -> String {
    let s = iconStroke(col)
    let g = "<g transform='translate(\(num(x)),\(num(y)))'>"
    switch c {
    case .wifi:
        return g + "<path d='M -6 1 A 8 8 0 0 1 6 1' \(s)/><path d='M -3.5 3.5 A 4.5 4.5 0 0 1 3.5 3.5' \(s)/><circle cx='0' cy='5.5' r='1.2' fill='\(col)'/></g>"
    case .ethernet, .thunderbolt:
        return g + "<rect x='-5' y='-3.5' width='10' height='7' rx='1.5' \(s)/><path d='M -3 3.5 v 2 M 0 3.5 v 2 M 3 3.5 v 2' \(s)/></g>"
    case .loopback:
        return g + "<path d='M 4 -1 A 4.5 4.5 0 1 1 2.8 -3.6' \(s)/><path d='M 2.6 -5.4 l 1.4 1.9 l -2.1 0.2 z' fill='\(col)' stroke='none'/></g>"
    case .tunnel, .cellular:
        return g + "<rect x='-4' y='0' width='8' height='6' rx='1' \(s)/><path d='M -2.5 0 v -1.5 A 2.5 2.5 0 0 1 2.5 -1.5 V 0' \(s)/></g>"
    case .bridge:
        return g + "<rect x='-6' y='-1.5' width='4' height='5.5' rx='1' \(s)/><rect x='2' y='-1.5' width='4' height='5.5' rx='1' \(s)/><path d='M -2 1 h 4' \(s)/></g>"
    default:
        return g + "<circle cx='0' cy='0' r='3' \(s)/></g>"
    }
}

/// A rough line-drawn glyph per peripheral kind — the SVG counterpart of the SF Symbol the
/// SwiftUI chip uses. Deliberately coarse: it's a 15px hint, not an illustration.
private func deviceIcon(_ k: USBDeviceKind, _ x: Double, _ y: Double, _ col: String) -> String {
    let s = iconStroke(col)
    let g = "<g transform='translate(\(num(x)),\(num(y)))'>"
    switch k {
    case .hub:
        return g + "<rect x='-7' y='-2' width='14' height='5' rx='1.5' \(s)/><path d='M -4 -2 v -3 M 0 -2 v -4 M 4 -2 v -3' \(s)/></g>"
    case .keyboard:
        return g + "<rect x='-8' y='-3.5' width='16' height='8' rx='1.5' \(s)/><path d='M -4.5 1.5 h 9' \(s)/></g>"
    case .pointing:
        return g + "<rect x='-4' y='-6' width='8' height='12' rx='4' \(s)/><path d='M 0 -6 v 4' \(s)/></g>"
    case .display:
        return g + "<rect x='-8' y='-5' width='16' height='10' rx='1.5' \(s)/><path d='M -3 7 h 6' \(s)/></g>"
    case .storage:
        return g + "<rect x='-7' y='-5' width='14' height='10' rx='1.5' \(s)/><circle cx='0' cy='0' r='2.5' \(s)/></g>"
    case .audio:
        return g + "<path d='M -6 3 v -3 A 6 6 0 0 1 6 0 v 3' \(s)/><rect x='-7.5' y='2' width='3' height='5' rx='1' \(s)/><rect x='4.5' y='2' width='3' height='5' rx='1' \(s)/></g>"
    case .camera:
        return g + "<rect x='-8' y='-4' width='16' height='9' rx='2' \(s)/><circle cx='0' cy='0.5' r='2.6' \(s)/></g>"
    case .computer:
        return g + "<rect x='-7' y='-5' width='14' height='9' rx='1.5' \(s)/><path d='M -9 6 h 18' \(s)/></g>"
    case .battery:
        return g + "<rect x='-8' y='-4' width='14' height='8' rx='1.5' \(s)/><path d='M 7 -1.5 v 3' \(s)/></g>"
    case .gamecontroller:
        return g + "<rect x='-8' y='-3.5' width='16' height='8' rx='4' \(s)/><path d='M -4.5 0.5 h 3 M -3 -1 v 3' \(s)/><circle cx='4' cy='0.5' r='1' fill='\(col)'/></g>"
    case .network:
        return g + "<rect x='-6' y='-3' width='12' height='7' rx='1.5' \(s)/><path d='M -3 4 v 2 M 0 4 v 2 M 3 4 v 2' \(s)/></g>"
    default:
        return g + "<rect x='-5' y='-5' width='10' height='10' rx='2' \(s)/></g>"
    }
}

/// Compact number (drops a trailing .0) for tidy SVG coordinates.
private func num(_ x: Double) -> String {
    x == x.rounded() ? String(Int(x)) : String(format: "%.1f", x)
}

private func xmlEsc(_ s: String) -> String {
    var r = ""
    for ch in s {
        switch ch {
        case "&": r += "&amp;"
        case "<": r += "&lt;"
        case ">": r += "&gt;"
        case "'": r += "&#39;"
        case "\"": r += "&quot;"
        default: r.append(ch)
        }
    }
    return r
}

extension ColorToken {
    /// CSS/SVG color — the web analog of the macOS `.swiftUI` palette.
    var css: String {
        switch self {
        case .link:           return "#3fb950"
        case .attach:         return "#39c5cf"
        case .neutral:        return "#8b949e"
        case .l2:             return "#a371f7"
        case .gatewayPrimary: return "#f0883e"
        case .gatewayVPN:     return "#58a6ff"
        case .gatewayOther:   return "#6e7681"
        case .egress:         return "#2dd4bf"
        case .split:          return "#f0a022"
        case .bandHardware:   return "rgba(139,148,158,0.05)"
        case .bandPhysical:   return "rgba(88,166,255,0.06)"
        case .bandDataLink:   return "rgba(163,113,247,0.06)"
        case .bandVirtual:    return "rgba(63,185,80,0.05)"
        case .clear:          return "none"
        }
    }
}

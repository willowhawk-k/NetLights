import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Server-side SVG renderer for the graph — the web/Linux analog of NetworkGraphView.
// It lives in Core so it has INTERNAL access to the GraphLayoutEngine geometry and the
// model types (so only ONE public entry point is needed, not a mass public-ification).
// The macOS app keeps using its SwiftUI renderer; this drives the Linux web UI.

/// Render a snapshot to a standalone SVG string, reusing the shared layout engine so the
/// OSI-band geometry is identical to the macOS graph. A fresh engine + cache per call
/// (one-shot per HTTP request); traffic animation is a later refinement.
public func renderGraphSVG(snapshot: TopologySnapshot, width: Double = 1200, height: Double = 760) -> String {
    let engine = GraphLayoutEngine(
        interfaces: snapshot.interfaces,
        trafficStates: [:],
        routes: snapshot.routes,
        gateways: snapshot.gateways,
        hardwarePorts: snapshot.hardwarePorts,
        attachedDevices: snapshot.attachedDevices,
        egress: snapshot.egress,
        systemPower: snapshot.systemPower,
        hideUnused: false,
        viewSize: CGSize(width: width, height: height),
        cache: LayoutCache())
    return engine.svgString()
}

extension GraphLayoutEngine {
    func svgString() -> String {
        let W = Double(bw), H = Double(bh)
        var o = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 \(num(W)) \(num(H))' "
              + "width='\(num(W))' height='\(num(H))' font-family='ui-monospace,SFMono-Regular,Menlo,monospace'>"
        o += "<rect x='0' y='0' width='\(num(W))' height='\(num(H))' fill='#0d1117'/>"

        // OSI bands (background tints + labels).
        for band in bands {
            let r = bandRect(band.id)
            o += "<rect x='0' y='\(num(Double(r.minY)))' width='\(num(W))' height='\(num(Double(r.height)))' fill='\(band.color.css)'/>"
            o += "<text x='12' y='\(num(Double(r.minY) + 15))' fill='#8b949e' font-size='11' font-weight='600'>\(xmlEsc(band.name))</text>"
            o += "<text x='\(num(W - 12))' y='\(num(Double(r.minY) + 15))' fill='#586069' font-size='10' text-anchor='end'>OSI \(xmlEsc(band.osiLabel))</text>"
        }

        // Connection wires (quadratic curves, same control points as the macOS graph).
        for line in buildLines() {
            let c = curveControl(line)
            let d = "M \(num(Double(line.from.x))) \(num(Double(line.from.y))) "
                  + "Q \(num(Double(c.x))) \(num(Double(c.y))) \(num(Double(line.to.x))) \(num(Double(line.to.y)))"
            let col = line.color.css
            // `class='wire'` + the carried interface let the browser toggle the ant-crawl
            // animation on wires whose interface has live traffic (rates derived client-side).
            let wire = "class='wire'" + (line.ifaceID.map { " data-iface='\(xmlEsc($0))'" } ?? "")
            if line.encapsulated {   // VPN tunnel: soft glow underlay + animatable dashed core
                o += "<path d='\(d)' fill='none' stroke='\(col)' stroke-width='7' stroke-opacity='0.18'/>"
                o += "<path \(wire) d='\(d)' fill='none' stroke='\(col)' stroke-width='2.5' stroke-opacity='0.9' stroke-dasharray='7 5'/>"
            } else {
                let dash = line.style == .data ? " stroke-dasharray='5 5'" : ""
                o += "<path \(wire) d='\(d)' fill='none' stroke='\(col)' stroke-width='\(line.dominant ? "2.4" : "1.4")' stroke-opacity='0.8'\(dash)/>"
            }
        }

        // Nodes.
        for iface in visible {
            if let p = ifacePositions[iface.id] { o += ifaceNode(p, iface) }
        }
        for port in hardwarePorts {
            if let p = hwPortPositions[port.id] { o += svgNode(p, 84, 38, stroke: "#6e7681", title: "TB \(port.id)", subtitle: "") }
        }
        for dev in attachedDevices {
            if let p = devicePositions[dev.id] { o += svgNode(p, 76, 34, stroke: "#39c5cf", title: dev.name, subtitle: "") }
        }
        for gw in gateways {
            if let p = gatewayPositions[gw.id] { o += gwNode(p, gw) }
        }
        if egress != nil, let p = egressPosition { o += egressNode(p, via: egress?.viaInterface ?? "") }
        if let sid = vpnServerID, let p = vpnServerPosition {
            o += svgNode(p, 100, 44, stroke: ColorToken.gatewayVPN.css, title: "VPN Server", subtitle: sid)
        }
        if hasVPNExcludes, let p = vpnExcludePosition {
            o += svgNode(p, 96, 42, stroke: ColorToken.split.css, title: "Direct", subtitle: "\(vpnExcludeRoutes.count) excluded")
        }

        o += "</svg>"
        return o
    }
}

// A rounded-rect node with a title + optional subtitle, centered on `p`.
private func svgNode(_ p: CGPoint, _ w: Double, _ h: Double, stroke: String, title: String, subtitle: String) -> String {
    let cx = Double(p.x), cy = Double(p.y)
    var s = "<rect x='\(num(cx - w / 2))' y='\(num(cy - h / 2))' width='\(num(w))' height='\(num(h))' rx='7' "
          + "fill='#161b22' stroke='\(stroke)' stroke-opacity='0.75'/>"
    s += "<text x='\(num(cx))' y='\(num(cy - 1))' fill='#e6edf3' font-size='11' text-anchor='middle'>\(xmlEsc(title))</text>"
    if !subtitle.isEmpty {
        s += "<text x='\(num(cx))' y='\(num(cy + 11))' fill='#8b949e' font-size='8' text-anchor='middle'>\(xmlEsc(subtitle))</text>"
    }
    return s
}

// MARK: - Richer node styling (card + category LED + drawn icon)

private func card(_ cx: Double, _ cy: Double, _ w: Double, _ h: Double, _ border: String) -> String {
    "<rect x='\(num(cx - w / 2))' y='\(num(cy - h / 2))' width='\(num(w))' height='\(num(h))' rx='8' fill='#161b22' stroke='\(border)' stroke-opacity='0.65'/>"
}

private func label(_ cx: Double, _ y: Double, _ text: String, _ size: Double, _ color: String) -> String {
    "<text x='\(num(cx))' y='\(num(y))' fill='\(color)' font-size='\(num(size))' text-anchor='middle'>\(xmlEsc(text))</text>"
}

private func ifaceNode(_ p: CGPoint, _ iface: InterfaceInfo) -> String {
    let cx = Double(p.x), cy = Double(p.y), w = 100.0, h = 54.0
    let color = categoryColor(iface.category)
    var s = card(cx, cy, w, h, color)
    s += categoryIcon(iface.category, cx, cy - h / 2 + 14, color)
    let led = iface.hasLink ? "#3fb950" : (iface.linkState == .down ? "#f85149" : "#6e7681")
    s += "<circle cx='\(num(cx + w / 2 - 9))' cy='\(num(cy - h / 2 + 9))' r='3.5' fill='\(led)'/>"
    s += label(cx, cy + 6, iface.id, 11, "#e6edf3")
    s += label(cx, cy + 18, iface.ipv4Addresses.first ?? iface.category.rawValue, 8, "#8b949e")
    return s
}

private func gwNode(_ p: CGPoint, _ gw: GatewayNode) -> String {
    let cx = Double(p.x), cy = Double(p.y), w = 104.0, h = 50.0
    let color = (gw.isVPN ? ColorToken.gatewayVPN : ColorToken.gatewayPrimary).css
    var s = card(cx, cy, w, h, color)
    let iy = cy - h / 2 + 12
    s += "<path d='M \(num(cx)) \(num(iy - 5)) L \(num(cx + 5)) \(num(iy)) L \(num(cx)) \(num(iy + 5)) L \(num(cx - 5)) \(num(iy)) Z' "
       + "fill='\(gw.isDefault ? color : "none")' stroke='\(color)' stroke-width='1.3'/>"
    s += label(cx, cy + 5, gw.titleLabel, 11, "#e6edf3")
    s += label(cx, cy + 17, gw.id, 8, "#8b949e")
    return s
}

private func egressNode(_ p: CGPoint, via: String) -> String {
    let cx = Double(p.x), cy = Double(p.y), w = 100.0, h = 52.0
    let color = ColorToken.egress.css
    var s = card(cx, cy, w, h, color)
    let iy = cy - h / 2 + 13
    let st = "stroke='\(color)' stroke-width='1.2' fill='none'"
    s += "<g transform='translate(\(num(cx)),\(num(iy)))'><circle r='6' \(st)/><ellipse rx='2.6' ry='6' \(st)/>"
       + "<path d='M -6 0 h 12 M -5 -3 h 10 M -5 3 h 10' \(st)/></g>"
    s += label(cx, cy + 6, "Internet", 11, "#e6edf3")
    s += label(cx, cy + 18, via, 8, "#8b949e")
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
    let s = "stroke='\(col)' stroke-width='1.3' fill='none' stroke-linecap='round'"
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

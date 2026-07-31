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
            guard let p = ifacePositions[iface.id] else { continue }
            o += svgNode(p, 96, 40, stroke: iface.hasLink ? "#3fb950" : "#484f58",
                         title: iface.id, subtitle: iface.ipv4Addresses.first ?? iface.category.rawValue)
        }
        for port in hardwarePorts {
            if let p = hwPortPositions[port.id] {
                o += svgNode(p, 84, 38, stroke: "#6e7681", title: "TB \(port.id)", subtitle: "")
            }
        }
        for dev in attachedDevices {
            if let p = devicePositions[dev.id] {
                o += svgNode(p, 76, 34, stroke: "#39c5cf", title: dev.name, subtitle: "")
            }
        }
        for gw in gateways {
            if let p = gatewayPositions[gw.id] {
                o += svgNode(p, 100, 42, stroke: (gw.isVPN ? ColorToken.gatewayVPN : ColorToken.gatewayPrimary).css,
                             title: gw.titleLabel, subtitle: gw.id)
            }
        }
        if egress != nil, let p = egressPosition {
            o += svgNode(p, 96, 44, stroke: ColorToken.egress.css, title: "Internet",
                         subtitle: egress?.viaInterface ?? "")
        }
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

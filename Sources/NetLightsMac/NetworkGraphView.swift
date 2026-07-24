import SwiftUI
import Combine

extension ColorToken {
    var swiftUI: Color {
        switch self {
        case .link:           return .green
        case .attach:         return .cyan
        case .neutral:        return Color(white: 0.55)
        case .l2:             return .purple
        case .gatewayPrimary: return .orange
        case .gatewayVPN:     return .blue
        case .gatewayOther:   return Color(white: 0.4)
        case .egress:         return .teal
        case .bandHardware:   return Color(white: 0.5).opacity(0.05)
        case .bandPhysical:   return Color.blue.opacity(0.055)
        case .bandDataLink:   return Color.purple.opacity(0.055)
        case .bandVirtual:    return Color.green.opacity(0.045)
        case .clear:          return .clear
        }
    }
}

// MARK: - NetworkGraphView

/// Which node the pointer is over. Tracked centrally (not per-node) so hover is
/// immune to the tracking-area churn the 0.75s auto-refresh would otherwise cause.
enum HoverTarget: Equatable {
    case iface(String)
    case port(Int)
    case gateway(String)
    case device(String)
    case link(String)    // a connection wire, identified by the interface it carries
    case tunnel(String)  // an encrypted VPN egress path — the VPN gateway id
}

/// Reports the rendered size of the tooltip so it can be clamped on-screen.
private struct TipSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct NetworkGraphView: View {
    let interfaces:    [InterfaceInfo]
    let trafficStates: [String: TrafficState]
    let routes:        [RouteEntry]
    let gateways:      [GatewayNode]
    let hardwarePorts: [HardwarePort]
    let attachedDevices: [AttachedDevice]
    let egress:        EgressInfo?
    let systemPower:   SystemPower?
    let hideUnused:    Bool

    @State private var viewSize: CGSize = .zero
    // dashPhase drives the ant-crawl on active traffic lines.
    // It only advances when there is traffic (no blink; just moving vs. static).
    @State private var dashPhase: CGFloat = 0

    // Central pointer-driven hover (see HoverTarget).
    @State private var pendingTarget: HoverTarget?
    @State private var shownTarget: HoverTarget?
    @State private var hoverTask: Task<Void, Never>?
    @State private var tipSize: CGSize = .zero
    // Pointer location captured when a wire hover begins. linkHoverPoint tracks the
    // PENDING target; shownLinkPoint is promoted from it only when the target is
    // committed — so a link tooltip's position and its content always agree (no
    // brief "old link's info at the new cursor spot" while the debounce settles).
    @State private var linkHoverPoint: CGPoint = .zero
    @State private var shownLinkPoint: CGPoint = .zero
    // Memo of the last wire hit-test: buildLines() is relatively expensive, so we
    // reuse the result while the pointer hasn't moved far enough to change it.
    @State private var lastWireProbePoint: CGPoint?
    @State private var lastWireProbeTarget: HoverTarget?

    // Per-frame layout memo (see LayoutCache). Keyed by `layoutSig`.
    @State private var layoutCache = LayoutCache()

    private let dashTimer = Timer.publish(every: 0.20, on: .main, in: .common).autoconnect()

    // MARK: - Layout engine delegation

    /// Rebuilt each `body` evaluation from the current inputs; the shared
    /// `layoutCache` (held in @State) carries memoization across rebuilds, so the
    /// geometry is computed once per signature exactly as before.
    private var engine: GraphLayoutEngine {
        GraphLayoutEngine(interfaces: interfaces, trafficStates: trafficStates,
                          routes: routes, gateways: gateways, hardwarePorts: hardwarePorts,
                          attachedDevices: attachedDevices, egress: egress,
                          systemPower: systemPower, hideUnused: hideUnused,
                          viewSize: viewSize, cache: layoutCache)
    }

    // Thin forwarders so the render + hover code calls the engine geometry
    // unchanged. Each returns the engine value verbatim.
    var visible: [InterfaceInfo] { engine.visible }
    var ifacePositions: [String: CGPoint] { engine.ifacePositions }
    var gatewayPositions: [String: CGPoint] { engine.gatewayPositions }
    var hwPortPositions: [Int: CGPoint] { engine.hwPortPositions }
    var devicePositions: [String: CGPoint] { engine.devicePositions }
    var egressPosition: CGPoint? { engine.egressPosition }
    private var bw: CGFloat { engine.bw }
    private var bh: CGFloat { engine.bh }
    private var bands: [LayerBand] { engine.bands }
    private var physFreeVisible: [InterfaceInfo] { engine.physFreeVisible }
    private var physicalUpperLaneCount: Int { engine.physicalUpperLaneCount }
    private var physBracketInset: CGFloat { engine.physBracketInset }
    private func bandRect(_ name: String) -> CGRect { engine.bandRect(name) }
    private func virtualGroupLayout(w: CGFloat) -> [(group: IfaceGroup, rect: CGRect)] { engine.virtualGroupLayout(w: w) }
    private func receptacleBSDs(_ port: HardwarePort) -> [String] { engine.receptacleBSDs(port) }
    private func portBracketLabel(_ p: HardwarePort) -> String { engine.portBracketLabel(p) }
    private func buildLines() -> [ConnLine] { engine.buildLines() }
    private func curveControl(_ line: ConnLine) -> CGPoint { engine.curveControl(line) }
    private func curveMidpoint(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint) -> CGPoint { engine.curveMidpoint(a, c, b) }
    private func distanceToCurve(_ p: CGPoint, _ a: CGPoint, _ c: CGPoint, _ b: CGPoint) -> CGFloat { engine.distanceToCurve(p, a, c, b) }
    private func hitRect(_ c: CGPoint, _ w: CGFloat, _ h: CGFloat) -> CGRect { engine.hitRect(c, w, h) }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            // Scroll when the window is smaller than the graph's natural size (bw/bh
            // floor at contentWidth/contentHeight), so bands and the device tree keep
            // full spacing and never compress/overlap — a narrow or short window (or an
            // iOS-sized screen) pans instead. When the window is larger, the graph fills it.
            ScrollView([.vertical, .horizontal]) {
            ZStack(alignment: .topLeading) {
                // Band backgrounds
                bandBGs(w: bw, h: bh)
                groupLabels(w: bw, h: bh)
                tbBrackets(h: bh)
                connectionLineViews()

                // Wi-Fi network entity (the AP), if Wi-Fi carries a default route.
                if let wp = hwPortPositions[-1] {
                    WifiEntityView(ssid: egress?.name).position(wp).zIndex(1)
                }

                // External-displays entity, if any monitors are attached.
                if let dp = hwPortPositions[-2] {
                    VideoEntityView(count: attachedDevices.filter { $0.receptacle == -2 }.count)
                        .position(dp).zIndex(1)
                }

                // Bluetooth entity, if any devices are connected (permission granted).
                if let btp = hwPortPositions[-4] {
                    BluetoothEntityView(count: attachedDevices.filter { $0.receptacle == -4 }.count)
                        .position(btp).zIndex(1)
                }

                // Battery entity (the Mac's own power), if this Mac has a battery.
                if let bp = hwPortPositions[-3], let power = systemPower {
                    BatteryEntityView(power: power).position(bp).zIndex(1)
                }

                // Hardware port nodes
                ForEach(hardwarePorts) { port in
                    if let p = hwPortPositions[port.id] {
                        HardwarePortNodeView(port: port, isHovered: shownTarget == .port(port.id))
                            .position(p).zIndex(1)
                    }
                }

                // Interface nodes
                ForEach(visible) { iface in
                    if let p = ifacePositions[iface.id] {
                        InterfaceNodeView(iface: iface,
                                         traffic: trafficStates[iface.id],
                                         isHovered: shownTarget == .iface(iface.id))
                            .position(p).zIndex(1)
                    }
                }

                // Gateway nodes (positioned in sidebar column)
                ForEach(gateways) { gw in
                    if let p = gatewayPositions[gw.id] {
                        GatewayNodeView(gateway: gw, isHovered: shownTarget == .gateway(gw.id))
                            .position(p).zIndex(1)
                    }
                }

                // Attached peripheral devices (audio, storage, …) beside their port
                ForEach(attachedDevices) { dev in
                    if let p = devicePositions[dev.id] {
                        DeviceNodeView(device: dev).position(p).zIndex(1)
                    }
                }

                // Egress ("Internet") node at the top of the gateway sidebar
                if let e = egress, let p = egressPosition {
                    EgressNodeView(egress: e).position(p).zIndex(1)
                }

                // Single, pointer-anchored tooltip (immune to per-node hover churn).
                tooltipLayer(in: CGSize(width: bw, height: bh))
            }
            .frame(width: bw, height: bh, alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p):
                    let t = targetAt(p)
                    if t != pendingTarget {
                        // Anchor a link tooltip at the entry point (no per-move
                        // state churn while sliding along the same wire).
                        switch t { case .link, .tunnel: linkHoverPoint = p; default: break }
                        pendingTarget = t; scheduleHover(t)
                    }
                case .ended:
                    pendingTarget = nil; scheduleHover(nil)
                }
            }
            }
            .onAppear {
                DispatchQueue.main.async {
                    if self.viewSize != geo.size { self.viewSize = geo.size }
                }
            }
            .onChange(of: geo.size) { newSize in
                viewSize = newSize
            }
            .onReceive(dashTimer) { _ in
                // Only advance when there is live traffic — static dashes when idle.
                if trafficStates.values.contains(where: { $0.rxActive || $0.txActive }) {
                    dashPhase -= 2
                }
            }
        }
    }

    // MARK: - Central hover / tooltip

    /// A single tooltip positioned right next to the hovered node and clamped so
    /// it always stays fully on-screen (placed above the node, flipped below when
    /// there's no room, and nudged horizontally to fit).
    @ViewBuilder
    private func tooltipLayer(in container: CGSize) -> some View {
        if let t = shownTarget, let c = hoverCenter(of: t) {
            tooltipContent
                .fixedSize()
                .background(GeometryReader { g in
                    Color.clear.preference(key: TipSizeKey.self, value: g.size)
                })
                .onPreferenceChange(TipSizeKey.self) { tipSize = $0 }
                .position(tipCenter(node: c, nodeSize: hoverSize(of: t),
                                    tipWidth: tipWidth(of: t), in: container))
                .allowsHitTesting(false)
                .zIndex(200)
        }
    }

    /// The fixed rendered width (content + padding) of each tooltip type — known
    /// up front, so the horizontal clamp never depends on async measurement.
    private func tipWidth(of t: HoverTarget) -> CGFloat {
        switch t {
        case .iface:   return 270
        case .gateway: return 260
        case .port:    return 230
        case .device:  return 232
        case .link:    return 230
        case .tunnel:  return 250
        }
    }

    /// Computes the tooltip's center so it sits adjacent to the node and never
    /// overflows the view bounds (shifted right near the left edge, and vice versa).
    private func tipCenter(node c: CGPoint, nodeSize n: CGSize,
                           tipWidth w: CGFloat, in container: CGSize) -> CGPoint {
        let h = max(tipSize.height, 40)
        let margin: CGFloat = 10
        let gap: CGFloat = 10
        let W = max(container.width, w + 2 * margin)
        let H = max(container.height, h + 2 * margin)

        // Prefer above the node; flip below if it would clip the top.
        var cy = c.y - n.height / 2 - gap - h / 2
        if cy - h / 2 < margin {
            cy = c.y + n.height / 2 + gap + h / 2
        }
        cy = min(max(cy, margin + h / 2), H - margin - h / 2)

        // Horizontally aligned to the node, clamped so the full box stays on-screen.
        let cx = min(max(c.x, margin + w / 2), W - margin - w / 2)
        return CGPoint(x: cx, y: cy)
    }

    @ViewBuilder
    private var tooltipContent: some View {
        switch shownTarget {
        case .iface(let id):
            if let i = interfaces.first(where: { $0.id == id }) {
                InterfaceTooltip(iface: i, routes: routes)
            }
        case .port(let id):
            if let p = hardwarePorts.first(where: { $0.id == id }) {
                HardwarePortTooltip(port: p)
            }
        case .gateway(let id):
            if let g = gateways.first(where: { $0.id == id }) {
                GatewayTooltip(gateway: g, routes: routes)
            }
        case .device(let id):
            if let d = attachedDevices.first(where: { $0.id == id }) {
                DeviceTooltip(device: d, portLabel: portLabel(d.receptacle))
            }
        case .link(let id):
            if let i = interfaces.first(where: { $0.id == id }) {
                LinkTooltip(iface: i, traffic: trafficStates[id])
            }
        case .tunnel(let id):
            if let g = gateways.first(where: { $0.id == id }) {
                VPNTunnelTooltip(gateway: g)
            }
        case .none:
            EmptyView()
        }
    }

    /// "Left · Front" style label for a receptacle, for device tooltips.
    private func portLabel(_ receptacle: Int) -> String? {
        guard let p = hardwarePorts.first(where: { $0.id == receptacle }), !p.side.isEmpty else { return nil }
        return p.position.isEmpty ? p.side : "\(p.side) · \(p.position)"
    }

    /// Hit-test the pointer against node rects (ports/gateways/interfaces don't overlap).
    private func targetAt(_ p: CGPoint) -> HoverTarget? {
        for port in hardwarePorts {
            if let c = hwPortPositions[port.id], hitRect(c, 84, 62).contains(p) { return .port(port.id) }
        }
        for gw in gateways {
            if let c = gatewayPositions[gw.id], hitRect(c, 100, 76).contains(p) { return .gateway(gw.id) }
        }
        let dp = devicePositions
        for dev in attachedDevices {
            if let c = dp[dev.id], hitRect(c, 74, 52).contains(p) { return .device(dev.id) }
        }
        for iface in visible {
            if let c = ifacePositions[iface.id], hitRect(c, 100, 90).contains(p) { return .iface(iface.id) }
        }
        // No node under the pointer → hit-test the connection wires (only those
        // tied to an interface). buildLines() is relatively expensive, so reuse the
        // last probe while the pointer hasn't moved far (the result won't change).
        if let lp = lastWireProbePoint, hypot(p.x - lp.x, p.y - lp.y) < 3 {
            return lastWireProbeTarget
        }
        // Pick the closest wire within a forgiving band so a thin curve is grabbable.
        var best: (line: ConnLine, d: CGFloat)?
        for line in buildLines() {
            guard line.ifaceID != nil else { continue }
            let d = distanceToCurve(p, line.from, curveControl(line), line.to)
            if d <= 16, best == nil || d < best!.d { best = (line, d) }
        }
        // An encapsulated (VPN) wire hovers as its encrypted tunnel, not a plain link.
        let result: HoverTarget? = best.flatMap { b in
            (b.line.encapsulated ? gateways.first(where: { $0.isVPN }).map { HoverTarget.tunnel($0.id) } : nil)
                ?? b.line.ifaceID.map { HoverTarget.link($0) }
        }
        lastWireProbePoint = p
        lastWireProbeTarget = result
        return result
    }

    /// Debounced commit of the hovered target — transient (refresh-induced) hovers
    /// are cancelled before they can open a popover.
    private func scheduleHover(_ t: HoverTarget?) {
        hoverTask?.cancel()
        hoverTask = Task { @MainActor in
            // Short show delay so the tooltip feels responsive; a slightly longer
            // hide delay avoids flicker when the pointer crosses a gap. Still long
            // enough that a fast sweep across wires doesn't pop transient tooltips.
            try? await Task.sleep(nanoseconds: t == nil ? 130_000_000 : 60_000_000)
            if Task.isCancelled { return }
            if pendingTarget == t {
                // Commit the anchor together with the content so they never disagree.
                shownLinkPoint = linkHoverPoint
                shownTarget = t
            }
        }
    }

    private func hoverCenter(of t: HoverTarget) -> CGPoint? {
        switch t {
        case .iface(let id):   return ifacePositions[id]
        case .port(let id):    return hwPortPositions[id]
        case .gateway(let id): return gatewayPositions[id]
        case .device(let id):  return devicePositions[id]
        case .link, .tunnel:
            // The committed anchor (matches the shown content), not the live
            // pending point — so it never shows the previous link's info here.
            return shownLinkPoint
        }
    }

    private func hoverSize(of t: HoverTarget) -> CGSize {
        switch t {
        case .iface:   return CGSize(width: 100, height: 90)
        case .port:    return CGSize(width: 84, height: 62)
        case .gateway: return CGSize(width: 100, height: 76)
        case .device:  return CGSize(width: 74, height: 52)
        case .link, .tunnel: return CGSize(width: 24, height: 24)
        }
    }

    // MARK: - Band backgrounds

    @ViewBuilder
    private func bandBGs(w: CGFloat, h: CGFloat) -> some View {
        let bw2   = max(w - gwColWidth, 100)
        ForEach(bands) { band in
            let rect = bandRect(band.name)
            VStack {
                Spacer()
                HStack {
                    Text(band.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.5))
                        .padding(.leading, 8).padding(.bottom, 4)
                    Spacer()
                    Text("OSI \(band.osiLabel)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.3))
                        .padding(.trailing, 8).padding(.bottom, 4)
                }
            }
            .frame(width: bw2, height: rect.height)
            .background(band.color.swiftUI)
            .border(Color(white: 0.5).opacity(0.07), width: 0.5)
            .position(x: gwColWidth + bw2 / 2, y: rect.midY)
        }
    }

    // MARK: - Group header labels

    @ViewBuilder
    private func groupLabels(w: CGFloat, h: CGFloat) -> some View {
        let bw2   = max(w - gwColWidth, 100)
        // Physical: label only the free groups, just above their row (which sits
        // beneath the anchored lanes — keep this in sync with ifacePositions).
        let physBand = bandRect("Physical")
        let pLanes   = physicalUpperLaneCount
        let pTotal   = max(pLanes + (physFreeVisible.isEmpty ? 0 : 1), 1)
        let pRowH    = max(physBand.height - physBracketInset, 1) / CGFloat(pTotal)
        labelRow(groups: subgroups(layer: "Physical", ifaces: physFreeVisible),
                 band: physBand, bw2: bw2,
                 labelY: physBand.minY + physBracketInset + pRowH * (CGFloat(pLanes) + 0.5) - 26)
        // Virtual: a header above each group, in whichever of the two rows it sits.
        ForEach(Array(virtualGroupLayout(w: bw2).enumerated()), id: \.offset) { _, item in
            let rect = item.rect
            Text(item.group.label)
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(.secondary.opacity(0.4))
                .position(x: gwColWidth + rect.midX, y: rect.minY + 10)
            if item.group.interfaces.count > 1 {
                Path { p in
                    p.move(to:    CGPoint(x: gwColWidth + rect.minX + 6, y: rect.minY + 18))
                    p.addLine(to: CGPoint(x: gwColWidth + rect.maxX - 6, y: rect.minY + 18))
                }
                .stroke(Color(white: 0.5).opacity(0.15), lineWidth: 0.5)
            }
        }
    }

    @ViewBuilder
    private func labelRow(groups: [IfaceGroup], band: CGRect, bw2: CGFloat, labelY: CGFloat) -> some View {
        let rects = uniformRects(groups: groups, band: band, w: bw2)
        ForEach(Array(groups.enumerated()), id: \.offset) { gi, group in
            if gi < rects.count {
                let rect = rects[gi]
                Text(group.label)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.4))
                    .position(x: gwColWidth + rect.midX, y: labelY)
                if group.interfaces.count > 1 {
                    Path { p in
                        p.move(to:    CGPoint(x: gwColWidth + rect.minX + 6, y: labelY + 8))
                        p.addLine(to: CGPoint(x: gwColWidth + rect.maxX - 6, y: labelY + 8))
                    }
                    .stroke(Color(white: 0.5).opacity(0.15), lineWidth: 0.5)
                }
            }
        }
    }

    // MARK: - Thunderbolt port brackets

    @ViewBuilder
    private func tbBrackets(h: CGFloat) -> some View {
        let physBand = bandRect("Physical")
        let bracketY = physBand.minY + 26
        ForEach(hardwarePorts) { port in
            let pts = receptacleBSDs(port).compactMap { ifacePositions[$0] }
            // Span only the top-row tiles. In a narrow window spreadAnchored can
            // wrap a receptacle's tiles to a lower lane; the bracket sits at the
            // band top, so spanning a wrapped tile's x would float misleadingly
            // above it. In the common single-row case all tiles share this row.
            if let topY = pts.map({ $0.y }).min() {
                let xs = pts.filter { abs($0.y - topY) < 1 }.map { $0.x }
                let minX = (xs.min() ?? 0) - 46
                let maxX = (xs.max() ?? 0) + 46
                let midX = (minX + maxX) / 2
                Path { p in
                    p.move(to:    CGPoint(x: minX, y: bracketY + 10))
                    p.addLine(to: CGPoint(x: minX, y: bracketY))
                    p.addLine(to: CGPoint(x: maxX, y: bracketY))
                    p.addLine(to: CGPoint(x: maxX, y: bracketY + 10))
                }
                .stroke(Color.orange.opacity(0.28), lineWidth: 1)
                Text(portBracketLabel(port))
                    .font(.system(size: 7.5, weight: .medium))
                    .foregroundColor(.orange.opacity(0.42))
                    .position(x: midX, y: bracketY - 6)
            }
        }
    }

    // MARK: - Connection lines

    @ViewBuilder
    private func connectionLineViews() -> some View {
        ForEach(buildLines()) { line in
            let active = line.hasTraffic
            let ctrl = curveControl(line)
            // Solid when physical, or a hard link that's currently idle.
            let drawSolid = line.style == .physical || (line.style == .link && !active)
            if line.encapsulated {
                // Encrypted VPN tunnel: a segmented "pipe" (animated casing ribs) around a
                // bright inner core, plus a soft neon glow — unmistakably an encapsulated,
                // encrypted path (vs plain / split-tunnel wires, which stay simple strokes).
                let tunnel = Path { p in
                    p.move(to: line.from)
                    p.addQuadCurve(to: line.to, control: ctrl)
                }
                // Soft glow, then a faint static core "wire", then the crawling ribs on
                // top — short bright marks with generous gaps so the motion is obvious and
                // reads as separate from the line.
                tunnel.stroke(line.color.swiftUI.opacity(0.12), lineWidth: 12).blur(radius: 3.5)
                tunnel.stroke(line.color.swiftUI.opacity(0.45), lineWidth: 1.5)
                tunnel.stroke(line.color.swiftUI.opacity(0.6),
                              style: StrokeStyle(lineWidth: 7, lineCap: .round, dash: [5, 12],
                                                 dashPhase: dashPhase * 1.6))
                    .animation(.easeInOut(duration: 0.35), value: active)
            } else {
                Path { p in
                    p.move(to: line.from)
                    p.addQuadCurve(to: line.to, control: ctrl)
                }
                .stroke(
                    line.color.swiftUI.opacity({
                        let base = drawSolid ? 0.5 : (active ? 0.55 : (line.emphasized ? 0.55 : 0.18))
                        return line.dominant ? max(base, 0.85) : base
                    }()),
                    style: {
                        let base = drawSolid ? (line.style == .physical ? 1.4 : 1.5)
                                             : (active ? 1.8 : (line.emphasized ? 1.6 : 0.9))
                        let w = line.dominant ? base + 1.6 : base
                        return drawSolid
                            ? StrokeStyle(lineWidth: w)
                            : StrokeStyle(lineWidth: w, dash: [5, 5], dashPhase: active ? dashPhase : 0)
                    }()
                )
                // A faded halo around the dominant path — fancy is cool.
                .shadow(color: line.dominant ? line.color.swiftUI.opacity(0.9) : .clear,
                        radius: line.dominant ? 6 : 0)
                .shadow(color: line.dominant ? line.color.swiftUI.opacity(0.5) : .clear,
                        radius: line.dominant ? 13 : 0)
                .animation(.easeInOut(duration: 0.35), value: active)
            }

            // Throughput on this wire, if it carries a single interface's flow and
            // that interface is moving data above the noise floor.
            let st   = (line.showRate ? line.ifaceID : nil).flatMap { trafficStates[$0] }
            let down = st.flatMap { formatRateShort($0.rxRate) }
            let up   = st.flatMap { formatRateShort($0.txRate) }
            let hasRate = down != nil || up != nil

            // The small static label ("L2"/"L3"/"VLAN"/…) — suppressed when a live
            // rate number is showing on the same wire so the two don't collide.
            if !line.label.isEmpty, !hasRate {
                Text(line.label)
                    .font(.system(size: 7.5))
                    .foregroundColor(active ? line.color.swiftUI.opacity(0.55)
                                     : (line.emphasized ? line.color.swiftUI.opacity(0.6) : .secondary.opacity(0.20)))
                    .position(x: ctrl.x, y: ctrl.y - 7)
                    .animation(.easeInOut(duration: 0.35), value: active)
            }

            if hasRate {
                wirePill(down: down, up: up, color: line.color.swiftUI)
                    .position(curveMidpoint(line.from, ctrl, line.to))
                    .allowsHitTesting(false)
            }
        }
    }

    /// The on-wire throughput pill — bold direction arrows set apart from their
    /// numbers, down and up grouped separately, so it reads cleanly even small.
    @ViewBuilder
    private func wirePill(down: String?, up: String?, color: Color) -> some View {
        HStack(spacing: 8) {
            if let down {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold))
                    Text(down).font(.system(size: 10, weight: .semibold, design: .rounded))
                }
            }
            if let up {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up").font(.system(size: 10, weight: .bold))
                    Text(up).font(.system(size: 10, weight: .semibold, design: .rounded))
                }
            }
        }
        .foregroundColor(color.opacity(0.98))
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.62)))
        .fixedSize()
    }

}

import SwiftUI

// MARK: - Constants

/// Width of the left gateway sidebar column.
private let gwColWidth: CGFloat = 120

// MARK: - Band layout (no Gateways — moved to sidebar)

private struct LayerBand: Identifiable {
    let id: String
    var name: String { id }
    let color: Color
    let osiLabel: String
    let heightFraction: CGFloat
}

private let allBands: [LayerBand] = [
    LayerBand(id: "Hardware",  color: Color(white: 0.5).opacity(0.05), osiLabel: "L0",  heightFraction: 0.15),
    LayerBand(id: "Physical",  color: Color.blue.opacity(0.055),       osiLabel: "L1",  heightFraction: 0.29),
    LayerBand(id: "Data Link", color: Color.purple.opacity(0.055),     osiLabel: "L2",  heightFraction: 0.13),
    LayerBand(id: "Virtual",   color: Color.green.opacity(0.045),      osiLabel: "L3+", heightFraction: 0.43),
]

private func bandRect(named name: String, h: CGFloat) -> CGRect {
    var y: CGFloat = 0
    for band in allBands {
        let bh = band.heightFraction * h
        if band.name == name { return CGRect(x: 0, y: y, width: 0, height: bh) }
        y += bh
    }
    return .zero
}

// MARK: - Sub-group helpers

private struct IfaceGroup { let label: String; let interfaces: [InterfaceInfo] }

private func subgroups(layer: String, ifaces: [InterfaceInfo]) -> [IfaceGroup] {
    let inLayer = ifaces.filter { $0.category.layerLabel == layer }
        .sorted { $0.groupKey == $1.groupKey ? $0.id < $1.id : $0.groupKey < $1.groupKey }
    var buckets: [String: (lbl: String, items: [InterfaceInfo])] = [:]
    var order: [String] = []
    for iface in inLayer {
        if buckets[iface.groupKey] == nil {
            order.append(iface.groupKey)
            buckets[iface.groupKey] = (groupLabel(iface), [])
        }
        buckets[iface.groupKey]!.items.append(iface)
    }
    return order.compactMap { k in buckets[k].map { IfaceGroup(label: $0.lbl, interfaces: $0.items) } }
}

private func groupLabel(_ s: InterfaceInfo) -> String {
    if s.isVirtualAdapter { return "App Adapters" }
    switch s.category {
    case .wifi:        return "Wi-Fi"
    case .ethernet:    return "Ethernet"
    case .thunderbolt: return "Thunderbolt"
    case .bridge:      return "Bridge"
    case .vlan:        return "VLAN"
    case .tunnel:      return "VPN / Tunnels"
    case .loopback:    return "Loopback"
    case .awdl:        return "Apple Wireless"
    case .cellular:    return "Cellular"
    case .other:       return "System"
    }
}

// MARK: - Connection line

private struct ConnLine: Identifiable {
    let id = UUID()
    let from, to: CGPoint
    let label: String
    let color: Color
    let hasTraffic: Bool
    var emphasized: Bool = false   // always-visible link (e.g. iPhone ↔ its port)
}

// MARK: - Layout helper (pure)

private func uniformRects(groups: [IfaceGroup], band: CGRect, w: CGFloat) -> [CGRect] {
    guard !groups.isEmpty else { return [] }
    let margin: CGFloat = 36
    let gap: CGFloat    = 20
    let nodeW: CGFloat  = 108
    let totalN = groups.map { $0.interfaces.count }.reduce(0, +)
    let usable = w - margin * 2 - CGFloat(groups.count - 1) * gap
    let wPerN  = min(nodeW, usable / CGFloat(max(totalN, 1)))
    var rects: [CGRect] = []
    var x = margin
    for group in groups {
        let gw = wPerN * CGFloat(group.interfaces.count)
        rects.append(CGRect(x: x, y: band.minY, width: gw, height: band.height))
        x += gw + gap
    }
    return rects
}

// MARK: - NetworkGraphView

/// Which node the pointer is over. Tracked centrally (not per-node) so hover is
/// immune to the tracking-area churn the 0.75s auto-refresh would otherwise cause.
enum HoverTarget: Equatable {
    case iface(String)
    case port(Int)
    case gateway(String)
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

    private let dashTimer = Timer.publish(every: 0.20, on: .main, in: .common).autoconnect()

    var visible: [InterfaceInfo] {
        hideUnused ? interfaces.filter { !$0.isUnused } : interfaces
    }

    /// BSD name → hardware-port id, derived from each port's child list.
    private var portForBSD: [String: Int] {
        var m: [String: Int] = [:]
        for port in hardwarePorts {
            for bsd in port.childBSDNames { m[bsd] = port.id }
        }
        return m
    }

    /// True when a Physical interface should sit directly beneath a hardware
    /// port node (TB bridge members, iPhone channels, USB Ethernet adapters, …).
    /// Everything else (Wi-Fi, VM/app adapters) is "free" and laid out separately.
    private func isAnchoredPhysical(_ iface: InterfaceInfo) -> Bool {
        guard let port = portForBSD[iface.id] else { return false }
        return hwPortPositions[port] != nil
    }

    /// Physical interfaces NOT anchored to a hardware port — grouped + labelled
    /// on their own lower row, the same way they were before HW-port anchoring.
    private var physFreeVisible: [InterfaceInfo] {
        visible.filter { $0.category.layerLabel == "Physical" && !isAnchoredPhysical($0) }
    }

    // MARK: - Band area geometry (everything right of the gateway sidebar)

    private var bw: CGFloat { max(viewSize.width - gwColWidth, 0) }
    private var bh: CGFloat { max(viewSize.height, 520) }

    // MARK: - Position maps (computed, not @State)

    var ifacePositions: [String: CGPoint] {
        guard bw > 0, bh > 0 else { return [:] }
        var result: [String: CGPoint] = [:]

        // Physical (L1) — two rows:
        //   • upper row: TB / iPhone interfaces anchored under their hardware port
        //   • lower row: free interfaces (Wi-Fi, USB Ethernet, app adapters) grouped
        let physBand = bandRect(named: "Physical", h: bh)
        let upperY   = physBand.minY + physBand.height * 0.42
        let lowerY   = physBand.minY + physBand.height * 0.84
        let hwPorts  = hwPortPositions

        // Anchored interfaces: spread symmetrically around their HW port's x.
        let bsdToPort = portForBSD
        var anchored: [Int: [InterfaceInfo]] = [:]
        for iface in visible where iface.category.layerLabel == "Physical" && isAnchoredPhysical(iface) {
            anchored[bsdToPort[iface.id] ?? 0, default: []].append(iface)
        }
        for (portId, ifaces) in anchored {
            guard let portPos = hwPorts[portId] else { continue }
            let sorted = ifaces.sorted { $0.id < $1.id }
            let n = sorted.count
            let spacing: CGFloat = 112   // > node width (100) so cards don't overlap
            // Center the cluster on the port, then clamp so it stays on-screen.
            let half = CGFloat(n - 1) / 2.0 * spacing
            let lo = gwColWidth + 36 + half
            let hi = gwColWidth + bw - 36 - half
            let centerX = min(max(portPos.x, lo), max(lo, hi))
            for (idx, iface) in sorted.enumerated() {
                let offsetX = (CGFloat(idx) - CGFloat(n - 1) / 2.0) * spacing
                result[iface.id] = CGPoint(x: centerX + offsetX, y: upperY)
            }
        }

        // Free interfaces: original grouped layout, on the lower row.
        let freeGroups = subgroups(layer: "Physical", ifaces: physFreeVisible)
        let freeRects  = uniformRects(groups: freeGroups, band: physBand, w: bw)
        for (gi, group) in freeGroups.enumerated() {
            guard gi < freeRects.count else { continue }
            let rect = freeRects[gi]
            let sp = rect.width / CGFloat(group.interfaces.count)
            for (ni, iface) in group.interfaces.enumerated() {
                let localX = rect.minX + sp * (CGFloat(ni) + 0.5)
                result[iface.id] = CGPoint(x: localX + gwColWidth, y: lowerY)
            }
        }

        // Data Link (L2) — bridges centered under their physical members
        let dlBand = bandRect(named: "Data Link", h: bh)
        for iface in visible.filter({ $0.category.layerLabel == "Data Link" }) {
            let lx: CGFloat
            if iface.category == .bridge, let mac = iface.macAddress {
                let prefix = String(mac.prefix(8))
                let xs = visible
                    .filter { ($0.category == .ethernet || $0.category == .thunderbolt)
                               && $0.macAddress?.hasPrefix(prefix) == true }
                    .compactMap { result[$0.id]?.x }
                lx = xs.isEmpty ? bw / 2 + gwColWidth : xs.reduce(0, +) / CGFloat(xs.count)
            } else {
                lx = bw / 2 + gwColWidth
            }
            result[iface.id] = CGPoint(x: lx, y: dlBand.midY)
        }

        // Virtual (L3+)
        let virtBand   = bandRect(named: "Virtual", h: bh)
        let virtNodeY  = virtBand.minY + virtBand.height * 0.45
        let virtGroups = subgroups(layer: "Virtual", ifaces: visible)
        let virtRects  = uniformRects(groups: virtGroups, band: virtBand, w: bw)
        for (gi, group) in virtGroups.enumerated() {
            guard gi < virtRects.count else { continue }
            let rect = virtRects[gi]
            let sp = rect.width / CGFloat(group.interfaces.count)
            for (ni, iface) in group.interfaces.enumerated() {
                let localX = rect.minX + sp * (CGFloat(ni) + 0.5)
                result[iface.id] = CGPoint(x: localX + gwColWidth, y: virtNodeY)
            }
        }

        return result
    }

    var gatewayPositions: [String: CGPoint] {
        guard viewSize.height > 0, !gateways.isEmpty else { return [:] }
        let h = viewSize.height
        let spacing  = min(96, (h - 104) / CGFloat(gateways.count))
        // Center the whole stack vertically in the sidebar.
        let startY = (h - spacing * CGFloat(gateways.count)) / 2
        var result: [String: CGPoint] = [:]
        for (i, gw) in gateways.enumerated() {
            result[gw.id] = CGPoint(x: gwColWidth / 2,
                                    y: startY + spacing * (CGFloat(i) + 0.5))
        }
        return result
    }

    var hwPortPositions: [Int: CGPoint] {
        guard bw > 0, bh > 0, !hardwarePorts.isEmpty else { return [:] }
        let band   = bandRect(named: "Hardware", h: bh)
        let margin: CGFloat = 60

        // Order the slots so the iPhone node sits immediately to the right of the
        // TB receptacle it's plugged into (making the "plugged into Port N" link
        // short and obvious). Unknown receptacle → iPhone goes at the end.
        let tbPorts = hardwarePorts.filter { !$0.isPhone }.sorted { $0.id < $1.id }
        let phone   = hardwarePorts.first { $0.isPhone }
        var order: [Int] = []
        // The iPhone is the active egress, so keep it hard against the gateway
        // bar (far left). Its actual receptacle port (if USB) goes right next to
        // it so the USB-C link stays short; the rest follow.
        if phone != nil {
            order.append(0)
            if let r = phone?.physicalReceptacle, tbPorts.contains(where: { $0.id == r }) {
                order.append(r)
            }
        }
        for p in tbPorts where !order.contains(p.id) { order.append(p.id) }

        let sp = (bw - margin * 2) / CGFloat(max(order.count, 1))
        var result: [Int: CGPoint] = [:]
        for (i, id) in order.enumerated() {
            result[id] = CGPoint(x: gwColWidth + margin + sp * (CGFloat(i) + 0.5),
                                 y: band.midY)
        }
        return result
    }

    /// Peripheral device chips, placed beside their hardware port (flipped to the
    /// inner side near the right edge), stacking down if a port has several.
    var devicePositions: [String: CGPoint] {
        guard bw > 0, bh > 0, !attachedDevices.isEmpty else { return [:] }
        var result: [String: CGPoint] = [:]
        var perPort: [Int: Int] = [:]
        for dev in attachedDevices {
            guard let base = hwPortPositions[dev.receptacle] else { continue }
            let idx = perPort[dev.receptacle, default: 0]; perPort[dev.receptacle] = idx + 1
            let dir: CGFloat = base.x > gwColWidth + bw * 0.62 ? -1 : 1
            result[dev.id] = CGPoint(x: base.x + dir * 104, y: base.y + CGFloat(idx) * 56)
        }
        return result
    }

    /// The egress ("Internet") node sits at the top of the gateway sidebar.
    var egressPosition: CGPoint? {
        guard egress != nil, viewSize.height > 0 else { return nil }
        return CGPoint(x: gwColWidth / 2, y: 60)
    }

    /// Where the egress link emerges: the hardware port the uplink is plugged
    /// into, or the uplink interface itself (e.g. internal Wi-Fi).
    private func egressAnchor() -> CGPoint? {
        guard let e = egress else { return nil }
        if let port = portForBSD[e.viaInterface], let p = hwPortPositions[port] { return p }
        return ifacePositions[e.viaInterface]
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Left sidebar: gateways
                gatewaySidebar(h: geo.size.height)

                // Vertical divider
                Path { p in
                    p.move(to:    CGPoint(x: gwColWidth, y: 0))
                    p.addLine(to: CGPoint(x: gwColWidth, y: max(geo.size.height, 520)))
                }
                .stroke(Color(white: 0.4).opacity(0.2), lineWidth: 0.5)

                // Band backgrounds (offset right of sidebar)
                bandBGs(w: geo.size.width, h: geo.size.height)
                groupLabels(w: geo.size.width, h: geo.size.height)
                tbBrackets(h: geo.size.height)
                connectionLineViews()

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
                tooltipLayer(in: geo.size)
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p):
                    let t = targetAt(p)
                    if t != pendingTarget { pendingTarget = t; scheduleHover(t) }
                case .ended:
                    pendingTarget = nil; scheduleHover(nil)
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
        case .none:
            EmptyView()
        }
    }

    /// Hit-test the pointer against node rects (ports/gateways/interfaces don't overlap).
    private func targetAt(_ p: CGPoint) -> HoverTarget? {
        for port in hardwarePorts {
            if let c = hwPortPositions[port.id], hitRect(c, 84, 62).contains(p) { return .port(port.id) }
        }
        for gw in gateways {
            if let c = gatewayPositions[gw.id], hitRect(c, 100, 76).contains(p) { return .gateway(gw.id) }
        }
        for iface in visible {
            if let c = ifacePositions[iface.id], hitRect(c, 100, 90).contains(p) { return .iface(iface.id) }
        }
        return nil
    }

    private func hitRect(_ c: CGPoint, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
    }

    /// Debounced commit of the hovered target — transient (refresh-induced) hovers
    /// are cancelled before they can open a popover.
    private func scheduleHover(_ t: HoverTarget?) {
        hoverTask?.cancel()
        hoverTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: t == nil ? 200_000_000 : 180_000_000)
            if Task.isCancelled { return }
            if pendingTarget == t { shownTarget = t }
        }
    }

    private func hoverCenter(of t: HoverTarget) -> CGPoint? {
        switch t {
        case .iface(let id):   return ifacePositions[id]
        case .port(let id):    return hwPortPositions[id]
        case .gateway(let id): return gatewayPositions[id]
        }
    }

    private func hoverSize(of t: HoverTarget) -> CGSize {
        switch t {
        case .iface:   return CGSize(width: 100, height: 90)
        case .port:    return CGSize(width: 84, height: 62)
        case .gateway: return CGSize(width: 100, height: 76)
        }
    }

    // MARK: - Gateway sidebar

    @ViewBuilder
    private func gatewaySidebar(h: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Gateways")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary.opacity(0.45))
                .padding(.leading, 8)
                .padding(.top, 8)
                .padding(.bottom, 6)
            Spacer()
            Text("OSI ext")
                .font(.system(size: 8))
                .foregroundColor(.secondary.opacity(0.25))
                .padding(.leading, 8)
                .padding(.bottom, 6)
        }
        .frame(width: gwColWidth, height: max(h, 520))
        .background(Color.orange.opacity(0.025))
    }

    // MARK: - Band backgrounds

    @ViewBuilder
    private func bandBGs(w: CGFloat, h: CGFloat) -> some View {
        let safeH = max(h, 520)
        let bw2   = max(w - gwColWidth, 100)
        ForEach(allBands) { band in
            let rect = bandRect(named: band.name, h: safeH)
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
            .background(band.color)
            .border(Color(white: 0.5).opacity(0.07), width: 0.5)
            .position(x: gwColWidth + bw2 / 2, y: rect.midY)
        }
    }

    // MARK: - Group header labels

    @ViewBuilder
    private func groupLabels(w: CGFloat, h: CGFloat) -> some View {
        let safeH = max(h, 520)
        let bw2   = max(w - gwColWidth, 100)
        // Physical: label only the free groups, just above their (lower) row.
        let physBand = bandRect(named: "Physical", h: safeH)
        labelRow(groups: subgroups(layer: "Physical", ifaces: physFreeVisible),
                 band: physBand, bw2: bw2,
                 labelY: physBand.minY + physBand.height * 0.84 - 26)
        // Virtual: labels at the top of the band, as before.
        let virtBand = bandRect(named: "Virtual", h: safeH)
        labelRow(groups: subgroups(layer: "Virtual", ifaces: visible),
                 band: virtBand, bw2: bw2, labelY: virtBand.minY + 12)
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
        let safeH    = max(h, 520)
        let physBand = bandRect(named: "Physical", h: safeH)
        let bracketY = physBand.minY + 26
        ForEach(hardwarePorts) { port in
            let xs = port.childBSDNames.compactMap { ifacePositions[$0]?.x }
            if !xs.isEmpty {
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

    private func portBracketLabel(_ p: HardwarePort) -> String {
        if p.isPhone {
            let loc = p.side.isEmpty ? "" : (p.position.isEmpty ? p.side : "\(p.side) · \(p.position)")
            return loc.isEmpty ? "iPhone · \(p.connectionMedium)"
                               : "iPhone · \(p.connectionMedium) (\(loc))"
        }
        guard !p.side.isEmpty else { return "TB Port \(p.id)" }
        let loc = p.position.isEmpty ? p.side : "\(p.side) · \(p.position)"
        return "TB Port \(p.id)  (\(loc))"
    }

    // MARK: - Connection lines

    @ViewBuilder
    private func connectionLineViews() -> some View {
        ForEach(buildLines()) { line in
            let active = line.hasTraffic
            Path { path in
                path.move(to: line.from)
                path.addQuadCurve(
                    to: line.to,
                    control: CGPoint(x: (line.from.x + line.to.x) / 2,
                                     y: (line.from.y + line.to.y) / 2 - 14))
            }
            // Active lines: brighter, moving ant-crawl.
            // Idle lines: dimmer, static dashes. No blinking — transitions are smooth.
            // Emphasized links (e.g. iPhone ↔ its port) stay clearly visible.
            .stroke(
                line.color.opacity(active ? 0.55 : (line.emphasized ? 0.55 : 0.18)),
                style: StrokeStyle(
                    lineWidth: active ? 1.8 : (line.emphasized ? 1.6 : 0.9),
                    dash:      [5, 5],
                    dashPhase: active ? dashPhase : 0
                )
            )
            .animation(.easeInOut(duration: 0.35), value: active)

            if !line.label.isEmpty {
                Text(line.label)
                    .font(.system(size: 7.5))
                    .foregroundColor(active ? line.color.opacity(0.55)
                                     : (line.emphasized ? line.color.opacity(0.6) : .secondary.opacity(0.20)))
                    .position(x: (line.from.x + line.to.x) / 2,
                               y: (line.from.y + line.to.y) / 2 - 20)
                    .animation(.easeInOut(duration: 0.35), value: active)
            }
        }
    }

    private func hasTraffic(_ name: String) -> Bool {
        let t = trafficStates[name]; return t?.rxActive == true || t?.txActive == true
    }

    private func buildLines() -> [ConnLine] {
        var lines: [ConnLine] = []

        // L0 → L1: hardware port → its interfaces. Real attached USB devices
        // (Ethernet adapters, iPhone channels) get an emphasized green link;
        // Thunderbolt-bridge pseudo-members stay a faint grey.
        for port in hardwarePorts {
            guard let from = hwPortPositions[port.id] else { continue }
            for bsd in port.childBSDNames {
                if let to = ifacePositions[bsd] {
                    let isDevice = port.isPhone || port.deviceChildren.contains(bsd)
                    lines.append(ConnLine(from: from, to: to, label: "",
                        color: isDevice ? .green : Color(white: 0.55),
                        hasTraffic: hasTraffic(bsd),
                        emphasized: isDevice))
                }
            }
        }

        // Hardware port → attached peripheral device chip.
        let devPos = devicePositions
        for dev in attachedDevices {
            if let from = hwPortPositions[dev.receptacle], let to = devPos[dev.id] {
                lines.append(ConnLine(from: from, to: to, label: "",
                    color: .cyan, hasTraffic: false, emphasized: true))
            }
        }

        // iPhone USB-C → the physical TB receptacle it's plugged into.
        if let phone = hardwarePorts.first(where: { $0.isPhone }),
           let recep = phone.physicalReceptacle,
           let phonePos = hwPortPositions[0],
           let portPos  = hwPortPositions[recep] {
            lines.append(ConnLine(from: portPos, to: phonePos, label: "USB-C",
                color: .green, hasTraffic: false, emphasized: true))
        }

        // L1 → L2: bridge ↔ member ports (MAC prefix match)
        for bridge in visible where bridge.category == .bridge {
            guard let bMac = bridge.macAddress else { continue }
            let prefix = String(bMac.prefix(8))
            for member in visible where
                (member.category == .ethernet || member.category == .thunderbolt)
                && member.macAddress?.hasPrefix(prefix) == true
            {
                if let f = ifacePositions[bridge.id], let t = ifacePositions[member.id] {
                    lines.append(ConnLine(from: f, to: t, label: "L2",
                        color: .purple, hasTraffic: hasTraffic(member.id)))
                }
            }
        }

        // L1 → L2: VLAN → parent
        for iface in visible where iface.category == .vlan {
            if let parent = visible.first(where: { $0.category == .ethernet || $0.category == .bridge }),
               let f = ifacePositions[iface.id], let t = ifacePositions[parent.id] {
                lines.append(ConnLine(from: f, to: t, label: "VLAN",
                    color: .purple, hasTraffic: hasTraffic(iface.id)))
            }
        }

        // L3: active tunnels → physical carrier.
        // VPN tunnels that have a gateway are routed through the gateway chain
        // below instead, so we don't draw a redundant direct tunnel→carrier line.
        let vpnTunnels = Set(gateways.filter { $0.isVPN }.flatMap { $0.reachableVia })
        let carrier = routes.first { $0.isDefault && !$0.interfaceName.hasPrefix("utun") }?.interfaceName
        if let carrier, let cPos = ifacePositions[carrier] {
            for tun in visible where tun.category == .tunnel && tun.hasLink && !vpnTunnels.contains(tun.id) {
                if let f = ifacePositions[tun.id] {
                    lines.append(ConnLine(from: f, to: cPos, label: "L3",
                        color: .orange, hasTraffic: hasTraffic(tun.id)))
                }
            }
        }

        // Interface → gateway (lines go left into the sidebar):
        //   • VPN tunnel (utun8) → VPN gateway
        //   • Wi-Fi (en0)       → Wi-Fi default gateway
        for gw in gateways {
            guard let gwP = gatewayPositions[gw.id] else { continue }
            for ifName in gw.reachableVia {
                if let ifP = ifacePositions[ifName] {
                    lines.append(ConnLine(from: ifP, to: gwP,
                        label: gw.isVPN ? "VPN" : (gw.isDefault ? "default" : ""),
                        color: gw.isVPN ? .blue : (gw.isDefault ? .orange : Color(white: 0.45)),
                        hasTraffic: hasTraffic(ifName),
                        emphasized: gw.isVPN))
                }
            }
        }

        // Internet egress emerges from the physical uplink (hardware port, or the
        // uplink interface like internal Wi-Fi) — not from the gateway.
        if let ep = egressPosition, let anchor = egressAnchor() {
            lines.append(ConnLine(from: anchor, to: ep, label: "",
                color: .teal, hasTraffic: false, emphasized: true))
        }

        // VPN gateway → physical egress gateway (10.2.81.187 → 10.59.0.1):
        // completes the chain utun8 → VPN GW → Wi-Fi GW → en0.
        if let vpnGW = gateways.first(where: { $0.isVPN }),
           let egress = gateways.first(where: { $0.isDefault && !$0.isVPN }),
           let vP = gatewayPositions[vpnGW.id],
           let eP = gatewayPositions[egress.id] {
            lines.append(ConnLine(from: vP, to: eP, label: "egress",
                color: .blue, hasTraffic: false, emphasized: true))
        }

        return lines
    }
}

import SwiftUI
import Combine

// MARK: - Constants

/// Gateway sidebar removed — gateways are now chips pinned to their host device.
/// Kept at 0 so existing `+ gwColWidth` offsets simply become no-ops.
private let gwColWidth: CGFloat = 0
/// Tiers reserved above the bands: the Internet row, then the gateway-chip tier.
/// The Internet node is 70pt tall, so the row must reserve enough height for it
/// to sit fully below the top edge (otherwise it clips the band boundary).
private let internetRowHeight: CGFloat = 80
private let gwTierHeight: CGFloat = 78
private let headerHeight: CGFloat = internetRowHeight + gwTierHeight

// MARK: - Band layout (no Gateways — moved to sidebar)

private struct LayerBand: Identifiable {
    let id: String
    var name: String { id }
    let color: Color
    let osiLabel: String
    let heightFraction: CGFloat
}

private let bandStyles: [String: (color: Color, osi: String)] = [
    "Hardware":  (Color(white: 0.5).opacity(0.05), "L0"),
    "Physical":  (Color.blue.opacity(0.055),       "L1"),
    "Data Link": (Color.purple.opacity(0.055),     "L2"),
    "Virtual":   (Color.green.opacity(0.045),      "L3+"),
]

/// Total leaf nodes in a device subtree — used to size the tidy-tree layout.
private func leafCount(_ d: AttachedDevice, _ childrenOf: [String: [AttachedDevice]]) -> Int {
    let kids = childrenOf[d.id] ?? []
    return kids.isEmpty ? 1 : kids.map { leafCount($0, childrenOf) }.reduce(0, +)
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
    var style: LinkStyle = .data
    var dominant: Bool = false     // part of the primary path most packets take
    var ifaceID: String? = nil     // interface this wire carries (rate + link hover)
    var showRate: Bool = false     // draw the throughput number on this wire
}

/// How a connector reads:
/// - `.physical`: a hard attachment (solid, never animates).
/// - `.link`: a hard link that also carries data — solid when idle, ant-crawl when busy.
/// - `.data`: a logical path (dashed; ant-crawl when busy).
enum LinkStyle { case physical, link, data }

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
    case device(String)
    case link(String)   // a connection wire, identified by the interface it carries
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

    /// BSD names of interfaces provided by a USB network device (MiFi, dongle) →
    /// they anchor under their device chip rather than a port.
    private var deviceInterfaceBSDs: Set<String> {
        Set(attachedDevices.compactMap { $0.interfaceBSD })
    }

    /// True when a Physical interface sits beneath a hardware entity: a port
    /// (TB members, iPhone channels), the Wi-Fi entity (en0), or a device chip
    /// (MiFi/dongle interface). Everything else (VM/app adapters) is "free".
    private func isAnchoredPhysical(_ iface: InterfaceInfo) -> Bool {
        // Use the (geometry-free) port ORDER, not hwPortPositions — the latter
        // depends on bandRect → bands → isAnchoredPhysical, which would recurse.
        let order = hwPortOrder
        if let port = portForBSD[iface.id], order.contains(port) { return true }
        if iface.id == wifiUplinkInterface, order.contains(-1) { return true }
        if deviceInterfaceBSDs.contains(iface.id) { return true }
        return false
    }

    /// Physical interfaces NOT anchored to a hardware port — grouped + labelled
    /// on their own lower row, the same way they were before HW-port anchoring.
    private var physFreeVisible: [InterfaceInfo] {
        visible.filter { $0.category.layerLabel == "Physical" && !isAnchoredPhysical($0) }
    }

    /// Lays anchored tiles in a single row, spread HORIZONTALLY so none overlap:
    /// sorted by x and pushed apart to at least `minGap`, then shifted to stay within
    /// the band width. We have far more horizontal than vertical room, so it only
    /// wraps into extra stacked rows when the window genuinely can't fit them. Returns
    /// each id's x + row index, and the row count. Geometry-free in x (no band rects).
    private func spreadAnchored(_ items: [(id: String, x: CGFloat)], minGap: CGFloat) -> (pos: [String: (x: CGFloat, lane: Int)], lanes: Int) {
        let loX = gwColWidth + 36, hiX = gwColWidth + bw - 36
        let avail = max(hiX - loX, minGap)
        let perRow = max(Int(avail / minGap) + 1, 1)
        let sorted = items.sorted { $0.x != $1.x ? $0.x < $1.x : $0.id < $1.id }
        guard !sorted.isEmpty else { return ([:], 1) }

        if sorted.count <= perRow {
            // One row: push right to keep >= minGap, then shift back to fit the band.
            var xs: [CGFloat] = []; var prev = -CGFloat.greatestFiniteMagnitude
            for it in sorted { let x = max(it.x, prev + minGap); xs.append(x); prev = x }
            if let last = xs.last, last > hiX { let d = last - hiX; for i in xs.indices { xs[i] -= d } }
            if let first = xs.first, first < loX {            // compress rightward from loX
                var p = loX - minGap
                for i in xs.indices { let x = max(xs[i], p + minGap); xs[i] = x; p = x }
            }
            var pos: [String: (x: CGFloat, lane: Int)] = [:]
            for (i, it) in sorted.enumerated() { pos[it.id] = (xs[i], 0) }
            return (pos, 1)
        }
        // Window-constrained: wrap into the fewest rows, evenly spaced within each.
        let lanes = (sorted.count + perRow - 1) / perRow
        let perLane = (sorted.count + lanes - 1) / lanes
        var pos: [String: (x: CGFloat, lane: Int)] = [:]
        for (i, it) in sorted.enumerated() {
            let lane = i / perLane, inLane = i % perLane
            let cnt = min(perLane, sorted.count - lane * perLane)
            pos[it.id] = (loX + (avail / CGFloat(cnt)) * (CGFloat(inLane) + 0.5), lane)
        }
        return (pos, lanes)
    }

    /// Desired x for every anchored Physical interface, grouped by the physical
    /// receptacle it belongs to — a TB-bridge member AND a dock's USB-Ethernet on the
    /// same port share one cluster spread symmetrically around it (so they sit
    /// side-by-side, not stacked); Wi-Fi anchors at its entity. Geometry-free in x.
    private func anchoredPhysicalLayout() -> [(id: String, x: CGFloat)] {
        let slots = hwSlotLayout
        var byReceptacle: [Int: [String]] = [:]
        for iface in visible where iface.category.layerLabel == "Physical" && isAnchoredPhysical(iface) {
            if let port = portForBSD[iface.id] {
                byReceptacle[port, default: []].append(iface.id)
            } else if iface.id == wifiUplinkInterface {
                byReceptacle[-1, default: []].append(iface.id)
            } else if let dev = attachedDevices.first(where: { $0.interfaceBSD == iface.id }) {
                byReceptacle[dev.receptacle, default: []].append(iface.id)
            }
        }
        let spacing: CGFloat = 112
        var out: [(id: String, x: CGFloat)] = []
        for (recep, ids) in byReceptacle {
            guard let s = slots[recep] else { continue }
            let sorted = ids.sorted(); let n = sorted.count
            let half = CGFloat(n - 1) / 2 * spacing
            let lo = gwColWidth + 36 + half, hi = gwColWidth + bw - 36 - half
            let centerX = min(max(s.center, lo), max(lo, hi))
            for (i, id) in sorted.enumerated() {
                out.append((id, centerX + (CGFloat(i) - CGFloat(n - 1) / 2) * spacing))
            }
        }
        return out
    }

    /// How many stacked rows the anchored Physical interfaces need (1 unless the
    /// window is too narrow to spread them horizontally). Geometry-free.
    private var physicalUpperLaneCount: Int {
        spreadAnchored(anchoredPhysicalLayout(), minGap: 112).lanes
    }

    // MARK: - Band area geometry (everything right of the gateway sidebar)

    private var bw: CGFloat { max(viewSize.width - gwColWidth, 0) }
    private var bh: CGFloat { max(viewSize.height, 520) }

    private let deviceRowGap: CGFloat = 50

    // MARK: - Device forest (USB hub → device hierarchy)

    /// The parent→children forest of attached devices: a device whose hub is
    /// present nests under it; everything else is a root on its hardware port.
    private var deviceForest: (childrenOf: [String: [AttachedDevice]],
                               rootsByPort: [Int: [AttachedDevice]]) {
        let byId = Dictionary(attachedDevices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var childrenOf: [String: [AttachedDevice]] = [:]
        var rootsByPort: [Int: [AttachedDevice]] = [:]
        for d in attachedDevices {
            if let pid = d.parentID, byId[pid] != nil {
                childrenOf[pid, default: []].append(d)
            } else {
                rootsByPort[d.receptacle, default: []].append(d)
            }
        }
        // Order siblings by type, then name, so chips read tidily at every level
        // of the tree (USB hub children, Bluetooth devices, displays).
        func byTypeThenName(_ a: AttachedDevice, _ b: AttachedDevice) -> Bool {
            a.kind.label == b.kind.label
                ? a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                : a.kind.label < b.kind.label
        }
        childrenOf = childrenOf.mapValues { $0.sorted(by: byTypeThenName) }
        rootsByPort = rootsByPort.mapValues { $0.sorted(by: byTypeThenName) }
        return (childrenOf, rootsByPort)
    }

    /// Deepest hub chain (edges from a root), so the Hardware band can reserve
    /// enough vertical room for the tree that hangs below the ports.
    private var deviceForestDepth: Int {
        let f = deviceForest
        func depth(_ d: AttachedDevice) -> Int {
            let kids = f.childrenOf[d.id] ?? []
            return kids.isEmpty ? 0 : 1 + (kids.map(depth).max() ?? 0)
        }
        return f.rootsByPort.values.flatMap { $0 }.map(depth).max() ?? 0
    }

    /// Whether the Virtual band actually fills its second row (mirrors the split
    /// in `virtualGroupLayout`), so it doesn't reserve height it won't use.
    private var virtualRowsUsed: Int {
        let groups = subgroups(layer: "Virtual", ifaces: visible)
        guard !groups.isEmpty else { return 0 }
        let total = groups.reduce(0) { $0 + $1.interfaces.count }
        let half  = (total + 1) / 2
        var counts = [0, 0]
        for g in groups { let r = counts[0] < half ? 0 : 1; counts[r] += g.interfaces.count }
        return counts[1] > 0 ? 2 : 1
    }

    // MARK: - Content-driven band sizing

    /// Bands size themselves to the entities they must show: the Hardware band
    /// grows with the depth of the USB device tree; Physical/Virtual shrink to the
    /// number of rows actually in use. Heights are proportional shares of the area
    /// below the header, so the bands always fill the view without overlapping.
    private var bands: [LayerBand] {
        let depth = deviceForestDepth
        let deviceLevels = attachedDevices.isEmpty ? 0 : depth + 1
        let hwNeed = 96 + CGFloat(deviceLevels) * deviceRowGap + 24

        // Physical needs one row per anchored lane (stacked so tiles never overlap)
        // plus one for the free/grouped interfaces.
        let lanes = physicalUpperLaneCount
        let freeGroups = subgroups(layer: "Physical", ifaces: physFreeVisible).count
        let physRows = max(lanes + (freeGroups > 0 ? 1 : 0), 1)
        let physNeed = CGFloat(physRows) * 96 + 24

        let hasDL = visible.contains { $0.category.layerLabel == "Data Link" }
        let dlNeed: CGFloat = hasDL ? 66 : 26

        let vNeed = CGFloat(max(virtualRowsUsed, 1)) * 118 + 20

        let needs = [("Hardware", hwNeed), ("Physical", physNeed),
                     ("Data Link", dlNeed), ("Virtual", vNeed)]
        let total = needs.reduce(0) { $0 + $1.1 }
        return needs.map { name, need in
            let s = bandStyles[name] ?? (Color.clear, "")
            return LayerBand(id: name, color: s.color, osiLabel: s.osi, heightFraction: need / total)
        }
    }

    private func bandRect(_ name: String) -> CGRect {
        let usable = max(bh - headerHeight, 0)
        var y: CGFloat = headerHeight
        for band in bands {
            let h = band.heightFraction * usable
            if band.name == name { return CGRect(x: 0, y: y, width: 0, height: h) }
            y += h
        }
        return .zero
    }

    // MARK: - Position maps (computed, not @State)

    var ifacePositions: [String: CGPoint] {
        guard bw > 0, bh > 0 else { return [:] }
        var result: [String: CGPoint] = [:]

        // Physical (L1) — anchored interfaces (TB members under their port, Wi-Fi,
        // device-provided USB-Ethernet) are spread HORIZONTALLY in one row so tiles
        // never overlap — e.g. a dock's USB-LAN sits beside the TB-bridge member at the
        // same port rather than stacked on it. Extra rows appear only if the window is
        // too narrow. Free interfaces (app/VM adapters) fill a grouped row below.
        let physBand = bandRect("Physical")
        let (anchoredPos, laneCount) = spreadAnchored(anchoredPhysicalLayout(), minGap: 112)
        let freeGroups = subgroups(layer: "Physical", ifaces: physFreeVisible)
        let totalRows  = max(laneCount + (freeGroups.isEmpty ? 0 : 1), 1)
        let rowH       = physBand.height / CGFloat(totalRows)
        func rowY(_ i: Int) -> CGFloat { physBand.minY + rowH * (CGFloat(i) + 0.5) }

        for (id, p) in anchoredPos {
            result[id] = CGPoint(x: p.x, y: rowY(p.lane))
        }

        // Free interfaces: grouped layout, in the row beneath the anchored lanes.
        let freeRects = uniformRects(groups: freeGroups, band: physBand, w: bw)
        let freeY = rowY(laneCount)
        for (gi, group) in freeGroups.enumerated() where gi < freeRects.count {
            let rect = freeRects[gi]
            let sp = rect.width / CGFloat(group.interfaces.count)
            for (ni, iface) in group.interfaces.enumerated() {
                result[iface.id] = CGPoint(x: rect.minX + sp * (CGFloat(ni) + 0.5) + gwColWidth, y: freeY)
            }
        }

        // Data Link (L2) — bridges centered under their physical members
        let dlBand = bandRect("Data Link")
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

        // Virtual (L3+) — two rows, groups balanced across them (like Hardware).
        for (group, rect) in virtualGroupLayout(w: bw) {
            let sp = rect.width / CGFloat(group.interfaces.count)
            let nodeY = rect.minY + rect.height * 0.62
            for (ni, iface) in group.interfaces.enumerated() {
                let localX = rect.minX + sp * (CGFloat(ni) + 0.5)
                result[iface.id] = CGPoint(x: localX + gwColWidth, y: nodeY)
            }
        }

        return result
    }

    /// Lays the Virtual-band subgroups across TWO rows (balanced by interface
    /// count). Returns each group with its x-rect (whose y/height encode its row),
    /// shared by node placement and the group headers.
    private func virtualGroupLayout(w: CGFloat) -> [(group: IfaceGroup, rect: CGRect)] {
        let band = bandRect("Virtual")
        let groups = subgroups(layer: "Virtual", ifaces: visible)
        guard !groups.isEmpty else { return [] }
        let total = groups.reduce(0) { $0 + $1.interfaces.count }
        let half  = (total + 1) / 2
        var rows: [[IfaceGroup]] = [[], []]
        var counts = [0, 0]
        for g in groups {
            let r = counts[0] < half ? 0 : 1
            rows[r].append(g); counts[r] += g.interfaces.count
        }
        let rowH = band.height / 2
        var out: [(IfaceGroup, CGRect)] = []
        for r in 0..<2 {
            let rb = CGRect(x: 0, y: band.minY + CGFloat(r) * rowH, width: 0, height: rowH)
            let rects = uniformRects(groups: rows[r], band: rb, w: w)
            for (i, g) in rows[r].enumerated() where i < rects.count { out.append((g, rects[i])) }
        }
        return out.map { (group: $0.0, rect: $0.1) }
    }

    /// Gateways are chips pinned to their host: default gateways sit in the top
    /// gateway tier above the column of the device/interface they live on; a VPN
    /// gateway pins just above its tunnel interface down in the Virtual row.
    var gatewayPositions: [String: CGPoint] {
        guard bw > 0, bh > 0, !gateways.isEmpty else { return [:] }
        let tierY = internetRowHeight + gwTierHeight / 2
        var result: [String: CGPoint] = [:]
        for gw in gateways {
            if gw.isVPN {
                if let tun = gw.reachableVia.first(where: { ifacePositions[$0] != nil }),
                   let p = ifacePositions[tun] {
                    result[gw.id] = CGPoint(x: p.x, y: p.y - 62)
                }
            } else if let hx = gatewayHostX(gw) {
                result[gw.id] = CGPoint(x: hx, y: tierY)
            }
        }
        return result
    }

    private func gatewayHostX(_ gw: GatewayNode) -> CGFloat? { gatewayHostAnchor(gw)?.x }

    /// The HARDWARE-row entity a default gateway lives on — the iPhone node, the
    /// Wi-Fi entity, a USB device chip (MiFi/dongle), or a TB port. The gateway's
    /// link emerges from here (not the L1 interface), so the flow reads
    /// interface → hardware entity → gateway → Internet.
    private func gatewayHostAnchor(_ gw: GatewayNode) -> CGPoint? {
        let phoneIfaces = Set(hardwarePorts.first { $0.isPhone }?.childBSDNames ?? [])
        if gw.id.hasPrefix("172.20.10.") || !Set(gw.reachableVia).isDisjoint(with: phoneIfaces) {
            return hwPortPositions[0]
        }
        // Anchor to the HIGHEST-PRIORITY interface that reaches this gateway
        // (reachableVia is ordered primary-first), so a gateway shared by Wi-Fi
        // and wired sits over whichever uplink actually wins.
        for ifn in gw.reachableVia {
            if let p = hostAnchorForInterface(ifn) { return p }
        }
        return egress.flatMap { ifacePositions[$0.viaInterface] }
    }

    /// The hardware-row entity for a given uplink interface.
    private func hostAnchorForInterface(_ ifn: String) -> CGPoint? {
        if ifn == wifiUplinkInterface, let p = hwPortPositions[-1] { return p }
        if let dev = attachedDevices.first(where: { $0.interfaceBSD == ifn }),
           let p = devicePositions[dev.id] { return p }
        if let port = portForBSD[ifn], let p = hwPortPositions[port] { return p }
        return ifacePositions[ifn]
    }

    /// The Wi-Fi interface carrying a default route — its AP becomes a Hardware-row
    /// entity (id -1 in hwPortPositions).
    private var wifiUplinkInterface: String? {
        for gw in gateways where gw.isDefault && !gw.isVPN {
            for ifn in gw.reachableVia where interfaces.first(where: { $0.id == ifn })?.category == .wifi {
                return ifn
            }
        }
        return nil
    }

    /// If Wi-Fi shares a gateway with a wired interface, the TB receptacle that
    /// wired buddy sits on — so the Wi-Fi entity can be placed right beside it and
    /// its gateway link doesn't cross unrelated ones.
    private var wifiBuddyPort: Int? {
        guard let wifi = wifiUplinkInterface,
              let gw = gateways.first(where: { $0.isDefault && $0.reachableVia.contains(wifi) && $0.reachableVia.count > 1 })
        else { return nil }
        for ifn in gw.reachableVia where ifn != wifi {
            if let dev = attachedDevices.first(where: { $0.interfaceBSD == ifn }) { return dev.receptacle }
            if let port = portForBSD[ifn] { return port }
        }
        return nil
    }

    private var hasDisplays: Bool { attachedDevices.contains { $0.receptacle == -2 } }
    private var hasBattery: Bool { systemPower != nil }
    private var hasBluetooth: Bool { attachedDevices.contains { $0.receptacle == -4 } }

    /// The ordered hardware-row slot ids (TB ports, iPhone = 0, Wi-Fi = -1,
    /// Displays = -2, Battery = -3). Deliberately free of band geometry so
    /// `isAnchoredPhysical` (and thus `bands`/`bandRect`) can use it without a
    /// layout recursion cycle.
    private var hwPortOrder: [Int] {
        let hasWifi = wifiUplinkInterface != nil
        guard !hardwarePorts.isEmpty || hasWifi || hasDisplays || hasBattery || hasBluetooth else { return [] }

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
        if hasWifi {
            // Place the Wi-Fi entity beside the wired interface it shares a gateway
            // with (so their gateway links sit together), else at the end.
            if let buddy = wifiBuddyPort, let idx = order.firstIndex(of: buddy) {
                order.insert(-1, at: idx + 1)
            } else {
                order.append(-1)
            }
        }
        // The "Displays" entity (-2) groups external monitors at the far end.
        if hasDisplays { order.append(-2) }
        // The "Bluetooth" entity (-4) groups connected BT devices.
        if hasBluetooth { order.append(-4) }
        // The Battery entity (-3) — the Mac's own power, at the far end.
        if hasBattery { order.append(-3) }
        return order
    }

    /// Per-slot horizontal REGIONS for the Hardware row. Each port/entity gets a
    /// width proportional to how many device leaves hang beneath it (with a sane
    /// minimum), packed left-to-right and centered. Both the port node and its
    /// whole device subtree live inside this region, so two ports' trees — and the
    /// links between them — can never overlap or cross ("don't cross the streams").
    /// Geometry-free in X (no bandRect), so it's safe to call from `hwPortPositions`.
    private var hwSlotLayout: [Int: (center: CGFloat, width: CGFloat)] {
        let order = hwPortOrder
        guard !order.isEmpty, bw > 0 else { return [:] }
        let f = deviceForest
        func leaves(_ id: Int) -> Int {
            (f.rootsByPort[id] ?? []).map { leafCount($0, f.childrenOf) }.reduce(0, +)
        }
        let minSlotW: CGFloat = 110   // room for a port node + its label
        let leafSlotW: CGFloat = 92   // ideal width per device leaf
        let margin: CGFloat = 46
        let avail = max(bw - margin * 2, 1)
        var need: [Int: CGFloat] = [:]
        for id in order { need[id] = max(minSlotW, CGFloat(leaves(id)) * leafSlotW) }
        let totalNeed = order.reduce(0) { $0 + (need[$1] ?? 0) }
        // If the content is wider than the view, scale every slot down together.
        let scale = totalNeed > avail ? avail / totalNeed : 1
        var x = gwColWidth + margin + max(0, (avail - totalNeed * scale) / 2)
        var out: [Int: (CGFloat, CGFloat)] = [:]
        for id in order {
            let w = (need[id] ?? minSlotW) * scale
            out[id] = (x + w / 2, w)
            x += w
        }
        return out
    }

    var hwPortPositions: [Int: CGPoint] {
        let slots = hwSlotLayout
        guard bw > 0, bh > 0, !slots.isEmpty else { return [:] }
        // Sit the ports near the TOP of the Hardware band so the device tree has
        // the rest of the (content-sized) band to hang down into.
        let portY = bandRect("Hardware").minY + 36
        return slots.mapValues { CGPoint(x: $0.center, y: portY) }
    }

    /// Peripheral device chips, laid as a tidy tree INSIDE their port's region
    /// (see `hwSlotLayout`): each leaf consumes one horizontal slot left-to-right
    /// and every hub is centered over the span of its children. Because each port's
    /// forest is confined to its own region, no two ports' trees or links overlap.
    var devicePositions: [String: CGPoint] {
        guard bw > 0, bh > 0, !attachedDevices.isEmpty else { return [:] }
        let hw = hwPortPositions
        let slots = hwSlotLayout
        let f = deviceForest
        let pad: CGFloat = 8
        var result: [String: CGPoint] = [:]

        for (recep, roots) in f.rootsByPort {
            guard let base = hw[recep], let region = slots[recep] else { continue }
            let sorted = roots.sorted { $0.id < $1.id }
            let leaves = max(sorted.map { leafCount($0, f.childrenOf) }.reduce(0, +), 1)
            let usable = max(region.width - pad * 2, 1)
            let slot = usable / CGFloat(leaves)
            let loX = region.center - region.width / 2 + 6
            let hiX = region.center + region.width / 2 - 6
            func clampX(_ x: CGFloat) -> CGFloat { min(max(x, loX), max(loX, hiX)) }

            var cursor = region.center - usable / 2
            let topY = base.y + 52
            // Lay a subtree left-to-right; return the node's center x (midpoint of
            // its children's span). Depth-capped as cheap insurance against a
            // pathological registry (parentID is structurally acyclic, but still).
            func place(_ d: AttachedDevice, _ depth: Int) -> CGFloat {
                let y = topY + CGFloat(min(depth, 24)) * deviceRowGap
                let kids = depth < 24 ? (f.childrenOf[d.id] ?? []).sorted { $0.id < $1.id } : []
                if kids.isEmpty {
                    let x = cursor + slot / 2
                    cursor += slot
                    result[d.id] = CGPoint(x: clampX(x), y: y)
                    return x
                }
                let xs = kids.map { place($0, depth + 1) }
                let x = (xs.first! + xs.last!) / 2
                result[d.id] = CGPoint(x: clampX(x), y: y)
                return x
            }
            for root in sorted { _ = place(root, 0) }
        }
        return result
    }

    /// The egress ("Internet") node sits centered in the top row.
    var egressPosition: CGPoint? {
        guard egress != nil, viewSize.width > 0 else { return nil }
        return CGPoint(x: viewSize.width / 2, y: internetRowHeight / 2)
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Band backgrounds
                bandBGs(w: geo.size.width, h: geo.size.height)
                groupLabels(w: geo.size.width, h: geo.size.height)
                tbBrackets(h: geo.size.height)
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
                tooltipLayer(in: geo.size)
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p):
                    let t = targetAt(p)
                    if t != pendingTarget {
                        // Anchor a link tooltip at the entry point (no per-move
                        // state churn while sliding along the same wire).
                        if case .link = t { linkHoverPoint = p }
                        pendingTarget = t; scheduleHover(t)
                    }
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
        case .device:  return 232
        case .link:    return 230
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
        var best: (id: String, d: CGFloat)?
        for line in buildLines() {
            guard let id = line.ifaceID else { continue }
            let d = distanceToCurve(p, line.from, curveControl(line), line.to)
            if d <= 16, best == nil || d < best!.d { best = (id, d) }
        }
        let result: HoverTarget? = best.map { .link($0.id) }
        lastWireProbePoint = p
        lastWireProbeTarget = result
        return result
    }

    /// Min distance from `p` to a quadratic Bézier, by sampling points along it.
    private func distanceToCurve(_ p: CGPoint, _ a: CGPoint, _ c: CGPoint, _ b: CGPoint) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        // Scale samples to length so spacing stays well under the hit threshold —
        // a fixed count leaves dead gaps between samples on long (400–600px) wires.
        let steps = max(12, Int(hypot(b.x - a.x, b.y - a.y) / 6))
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let mt = 1 - t
            let x = mt * mt * a.x + 2 * mt * t * c.x + t * t * b.x
            let y = mt * mt * a.y + 2 * mt * t * c.y + t * t * b.y
            best = min(best, hypot(p.x - x, p.y - y))
        }
        return best
    }

    private func hitRect(_ c: CGPoint, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
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
        case .link:
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
        case .link:    return CGSize(width: 24, height: 24)
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
            .background(band.color)
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
        let pRowH    = physBand.height / CGFloat(pTotal)
        labelRow(groups: subgroups(layer: "Physical", ifaces: physFreeVisible),
                 band: physBand, bw2: bw2,
                 labelY: physBand.minY + pRowH * (CGFloat(pLanes) + 0.5) - 26)
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

    /// All interface tiles sitting on a port's physical receptacle: its own child
    /// interfaces (TB-bridge members, iPhone channels) PLUS any device-provided
    /// interface (e.g. a dock's USB-Ethernet) attached to the same receptacle.
    /// Mirrors the `byReceptacle` grouping in `anchoredPhysicalLayout`, so the
    /// bracket spans every tile that layout placed under this port.
    private func receptacleBSDs(_ port: HardwarePort) -> [String] {
        var ids = Set(port.childBSDNames)
        for dev in attachedDevices where dev.receptacle == port.id {
            if let bsd = dev.interfaceBSD { ids.insert(bsd) }
        }
        return Array(ids)
    }

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

    private func portBracketLabel(_ p: HardwarePort) -> String {
        if p.isPhone {
            let loc = p.side.isEmpty ? "" : (p.position.isEmpty ? p.side : "\(p.side) · \(p.position)")
            return loc.isEmpty ? "\(p.deviceName) · \(p.connectionMedium)"
                               : "\(p.deviceName) · \(p.connectionMedium) (\(loc))"
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
            let ctrl = curveControl(line)
            // Solid when physical, or a hard link that's currently idle.
            let drawSolid = line.style == .physical || (line.style == .link && !active)
            Path { p in
                p.move(to: line.from)
                p.addQuadCurve(to: line.to, control: ctrl)
            }
            .stroke(
                line.color.opacity({
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
            .shadow(color: line.dominant ? line.color.opacity(0.9) : .clear,
                    radius: line.dominant ? 6 : 0)
            .shadow(color: line.dominant ? line.color.opacity(0.5) : .clear,
                    radius: line.dominant ? 13 : 0)
            .animation(.easeInOut(duration: 0.35), value: active)

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
                    .foregroundColor(active ? line.color.opacity(0.55)
                                     : (line.emphasized ? line.color.opacity(0.6) : .secondary.opacity(0.20)))
                    .position(x: ctrl.x, y: ctrl.y - 7)
                    .animation(.easeInOut(duration: 0.35), value: active)
            }

            if hasRate {
                wirePill(down: down, up: up, color: line.color)
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

    /// Point on a quadratic Bézier at t = 0.5 — the visual middle of the wire.
    private func curveMidpoint(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: 0.25 * a.x + 0.5 * c.x + 0.25 * b.x,
                y: 0.25 * a.y + 0.5 * c.y + 0.25 * b.y)
    }

    /// Control point for a connector's quadratic curve, bowed perpendicular to the
    /// line by a deterministic amount so collinear / parallel lines arc apart and
    /// stay individually legible instead of stacking on one path.
    private func curveControl(_ line: ConnLine) -> CGPoint {
        let mx = (line.from.x + line.to.x) / 2
        let my = (line.from.y + line.to.y) / 2
        // Physical attachments (port→device, hub→child, USB-C cable) are drawn
        // STRAIGHT: the device tree is laid out so sibling subtrees never overlap,
        // and the perpendicular bow used for logical links would make these short
        // fanning lines cross each other unnecessarily.
        if line.style == .physical { return CGPoint(x: mx, y: my) }
        let dx = line.to.x - line.from.x
        let dy = line.to.y - line.from.y
        let len = max(hypot(dx, dy), 1)
        let nx = -dy / len, ny = dx / len   // unit normal
        // Stable sign from endpoints (not the per-render UUID) so it doesn't flicker.
        let salt = Int(line.from.x * 3 + line.from.y * 7 + line.to.x * 11 + line.to.y * 17)
        let sign: CGFloat = (salt & 1 == 0) ? 1 : -1
        let bow = sign * min(26, len * 0.12)
        return CGPoint(x: mx + nx * bow, y: my + ny * bow)
    }

    private func hasTraffic(_ name: String) -> Bool {
        let t = trafficStates[name]; return t?.rxActive == true || t?.txActive == true
    }

    private func buildLines() -> [ConnLine] {
        var lines: [ConnLine] = []

        // The dominant path most packets take: the winning physical default
        // gateway (precedence-sorted first non-VPN), its best interface, and the
        // VPN that rides it (if any). These links are drawn extra-bold.
        let physDefault = gateways.first { $0.isDefault && !$0.isVPN }
        let domGwID = physDefault?.id
        let domIface = physDefault?.reachableVia.first
        let domVpnID = gateways.first { $0.isDefault && $0.isVPN }?.id

        // L0 → L1: hardware port → its interfaces. Real attached USB devices
        // (Ethernet adapters, iPhone channels) get an emphasized green link;
        // Thunderbolt-bridge pseudo-members stay a faint grey.
        for port in hardwarePorts {
            guard let portP = hwPortPositions[port.id] else { continue }
            for bsd in port.childBSDNames {
                if let ifaceP = ifacePositions[bsd] {
                    let isDevice = port.isPhone || port.deviceChildren.contains(bsd)
                    // interface → hardware entity, so the ant-crawl flows OUTBOUND (up).
                    lines.append(ConnLine(from: ifaceP, to: portP, label: "",
                        color: isDevice ? .green : Color(white: 0.55),
                        hasTraffic: hasTraffic(bsd),
                        emphasized: isDevice, style: .link, dominant: bsd == domIface,
                        ifaceID: bsd, showRate: true))
                }
            }
        }

        // Hardware port → attached device chip, and (for network devices) the
        // chip → the interface it provides (e.g. MiFi → en10). Both are hard
        // physical attachments → solid.
        let devPos = devicePositions
        let devById = Dictionary(attachedDevices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for dev in attachedDevices {
            // Hard physical attachment (solid): from the parent hub if this device
            // hangs off one, otherwise from the hardware port / entity it sits on.
            let from: CGPoint? = (dev.parentID.flatMap { devById[$0] != nil ? devPos[$0] : nil })
                                 ?? hwPortPositions[dev.receptacle]
            if let from, let to = devPos[dev.id] {
                lines.append(ConnLine(from: from, to: to, label: "",
                    color: .cyan, hasTraffic: false, emphasized: true, style: .physical))
            }
            // Device chip → the interface it provides: a hard link that ant-crawls
            // only when there's traffic.
            if let bsd = dev.interfaceBSD, let chip = devPos[dev.id], let ifaceP = ifacePositions[bsd] {
                // interface → device chip, so the ant-crawl flows OUTBOUND (up).
                lines.append(ConnLine(from: ifaceP, to: chip, label: "",
                    color: .green, hasTraffic: hasTraffic(bsd), emphasized: true,
                    style: .link, dominant: bsd == domIface,
                    ifaceID: bsd, showRate: true))
            }
        }

        // iPhone USB-C → the physical TB receptacle it's plugged into.
        if let phone = hardwarePorts.first(where: { $0.isPhone }),
           let recep = phone.physicalReceptacle,
           let phonePos = hwPortPositions[0],
           let portPos  = hwPortPositions[recep] {
            // The USB-C cable is a physical attachment.
            lines.append(ConnLine(from: portPos, to: phonePos, label: "USB-C",
                color: .green, hasTraffic: false, emphasized: true, style: .physical))
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
                        color: .purple, hasTraffic: hasTraffic(member.id),
                        ifaceID: member.id))
                }
            }
        }

        // L1 → L2: VLAN → parent
        for iface in visible where iface.category == .vlan {
            if let parent = visible.first(where: { $0.category == .ethernet || $0.category == .bridge }),
               let f = ifacePositions[iface.id], let t = ifacePositions[parent.id] {
                lines.append(ConnLine(from: f, to: t, label: "VLAN",
                    color: .purple, hasTraffic: hasTraffic(iface.id),
                    ifaceID: iface.id))
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
                        color: .orange, hasTraffic: hasTraffic(tun.id),
                        ifaceID: tun.id, showRate: true))
                }
            }
        }

        // Gateway → its host. The link emerges from the HARDWARE-row entity the
        // uplink lives on (device chip / port / iPhone / Wi-Fi entity); the L1
        // interface connects up to that entity separately, so the flow reads
        // interface → hardware entity → gateway → Internet.
        let wifiUplink = wifiUplinkInterface
        for gw in gateways {
            guard let gwP = gatewayPositions[gw.id] else { continue }
            // One link per interface that reaches this gateway. The first
            // (highest-priority) interface is the bold/active link; any others
            // are faint alternates labeled with their interface, so a shared
            // gateway shows which uplink wins and which are backups.
            let vias = gw.reachableVia.isEmpty ? [""] : gw.reachableVia
            for (i, ifn) in vias.enumerated() {
                let host = ifn.isEmpty ? gatewayHostAnchor(gw) : hostAnchorForInterface(ifn)
                guard let from = host else { continue }
                let primary = (i == 0)
                lines.append(ConnLine(from: from, to: gwP,
                    label: primary ? (gw.isVPN ? "VPN" : "") : "\(i + 1)·\(ifn)",
                    color: gw.isVPN ? .blue : (primary ? .orange : Color(white: 0.4)),
                    hasTraffic: hasTraffic(ifn),
                    emphasized: primary && (gw.isVPN || gw.isDefault),
                    dominant: primary && (gw.id == domGwID || gw.id == domVpnID),
                    ifaceID: ifn.isEmpty ? nil : ifn))
            }
        }

        // The Wi-Fi interface (en0) connects up to its AP entity.
        if let wifi = wifiUplink, let wp = hwPortPositions[-1], let ifP = ifacePositions[wifi] {
            lines.append(ConnLine(from: ifP, to: wp, label: "",
                color: Color(white: 0.55), hasTraffic: hasTraffic(wifi),
                style: .link, dominant: wifi == domIface,
                ifaceID: wifi, showRate: true))
        }

        // Each default gateway chip → the Internet node at the top.
        if let ep = egressPosition {
            for gw in gateways where gw.isDefault && !gw.isVPN {
                if let gp = gatewayPositions[gw.id] {
                    lines.append(ConnLine(from: gp, to: ep, label: "",
                        color: .teal, hasTraffic: gatewayActive(gw), emphasized: true,
                        dominant: gw.id == domGwID, ifaceID: gw.reachableVia.first))
                }
            }
        }

        // VPN gateway → the L1 interface it egresses through (its encrypted
        // traffic enters the physical stack there, then rides that interface out).
        if let vpnGW = gateways.first(where: { $0.isVPN }),
           let vP = gatewayPositions[vpnGW.id],
           let dIface = domIface, let to = ifacePositions[dIface] {
            lines.append(ConnLine(from: vP, to: to, label: "egress",
                color: .blue, hasTraffic: gatewayActive(vpnGW), emphasized: true, dominant: true,
                ifaceID: dIface))
        }

        return lines
    }

    /// True when any interface that reaches this gateway has live traffic.
    private func gatewayActive(_ gw: GatewayNode) -> Bool {
        gw.reachableVia.contains { hasTraffic($0) }
    }
}

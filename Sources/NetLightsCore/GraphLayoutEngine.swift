import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Constants

/// Gateway sidebar removed — gateways are now chips pinned to their host device.
/// Kept at 0 so existing `+ gwColWidth` offsets simply become no-ops.
let gwColWidth: CGFloat = 0
/// Tiers reserved above the bands: the Internet row, then the gateway-chip tier.
/// The Internet node is 70pt tall, so the row must reserve enough height for it
/// to sit fully below the top edge (otherwise it clips the band boundary).
private let internetRowHeight: CGFloat = 80
private let gwTierHeight: CGFloat = 78
private let headerHeight: CGFloat = internetRowHeight + gwTierHeight
/// A tier reserved ABOVE the Internet row for the far-side VPN concentrator node.
/// Only claimed when an active VPN's server is resolved (see `farOffset`), so
/// non-VPN graphs keep their original extent.
private let farRowHeight: CGFloat = 88

// MARK: - Band layout (no Gateways — moved to sidebar)

struct LayerBand: Identifiable {
    let id: String
    var name: String { id }
    let color: ColorToken
    let osiLabel: String
    let heightFraction: CGFloat
}

private let bandStyles: [String: (color: ColorToken, osi: String)] = [
    "Hardware":  (.bandHardware, "L0"),
    "Physical":  (.bandPhysical, "L1"),
    "Data Link": (.bandDataLink, "L2"),
    "Virtual":   (.bandVirtual,  "L2+"),
]

/// Total leaf nodes in a device subtree — used to size the tidy-tree layout.
private func leafCount(_ d: AttachedDevice, _ childrenOf: [String: [AttachedDevice]]) -> Int {
    let kids = childrenOf[d.id] ?? []
    return kids.isEmpty ? 1 : kids.map { leafCount($0, childrenOf) }.reduce(0, +)
}

// MARK: - Sub-group helpers

struct IfaceGroup { let label: String; let interfaces: [InterfaceInfo] }

func subgroups(layer: String, ifaces: [InterfaceInfo]) -> [IfaceGroup] {
    let inLayer = ifaces.filter { $0.effectiveLayer == layer }
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
    if s.isVirtualAdapter { return "Virtual Adapters" }
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

struct ConnLine: Identifiable {
    let id = UUID()
    let from, to: CGPoint
    let label: String
    var color: ColorToken          // recolored when a line is folded into the VPN pipe
    let hasTraffic: Bool
    var emphasized: Bool = false   // always-visible link (e.g. iPhone ↔ its port)
    var style: LinkStyle = .data
    var dominant: Bool = false     // part of the primary path most packets take
    var ifaceID: String? = nil     // interface this wire carries (rate + link hover)
    var showRate: Bool = false     // draw the throughput number on this wire
    var encapsulated: Bool = false // (VPN) the tunneled outer path — drawn with an encapsulation sheath
    var laneBias: CGFloat = 0      // extra perpendicular bow, to run parallel beside another wire
}

/// How a connector reads:
/// - `.physical`: a hard attachment (solid, never animates).
/// - `.link`: a hard link that also carries data — solid when idle, ant-crawl when busy.
/// - `.data`: a logical path (dashed; ant-crawl when busy).
enum LinkStyle { case physical, link, data }

/// Renderer-neutral color reference emitted by the layout geometry, so the engine
/// carries no SwiftUI dependency. The SwiftUI renderer maps each token back to the
/// EXACT `Color` it replaced (keeps the macOS graph pixel-identical); a future web/SVG
/// renderer maps it to its own palette. (The enum is portable → moves to NetLightsCore;
/// the `swiftUI` mapping below stays in the macOS renderer.)
enum ColorToken: Equatable {
    case link, attach, neutral, l2, gatewayPrimary, gatewayVPN, gatewayOther, egress, split
    case bandHardware, bandPhysical, bandDataLink, bandVirtual, clear
}

// MARK: - Layout helper (pure)

/// Horizontal gap between adjacent groups in a uniform row. Shared with
/// `computeContentWidth` so the canvas it asks for accounts for the same gaps.
let uniformGroupGap: CGFloat = 20

func uniformRects(groups: [IfaceGroup], band: CGRect, w: CGFloat) -> [CGRect] {
    guard !groups.isEmpty else { return [] }
    let margin: CGFloat = 36
    let gap = uniformGroupGap
    let nodeW: CGFloat  = 108
    let totalN = groups.map { $0.interfaces.count }.reduce(0, +)
    let usable = w - margin * 2 - CGFloat(groups.count - 1) * gap
    // Floor at the drawn box width: compressing the pitch below the tile just overlaps the
    // tiles, which is strictly worse than letting the canvas scroll. Belt and braces behind
    // the contentWidth fix — a canvas can still be narrower than the content on a small
    // window, and the graph should stay legible when it is.
    let wPerN  = max(min(nodeW, usable / CGFloat(max(totalN, 1))), GraphNodeSize.iface.w)
    // Center the packed groups in the band: when the content is narrower than the
    // usable span (few interfaces, or "Hide inactive"), it would otherwise be left-
    // aligned while every other band centers. With full content the offset is ~0.
    let contentW = wPerN * CGFloat(totalN) + gap * CGFloat(groups.count - 1)
    var rects: [CGRect] = []
    var x = margin + max(0, (w - margin * 2 - contentW) / 2)
    for group in groups {
        let gw = wPerN * CGFloat(group.interfaces.count)
        rects.append(CGRect(x: x, y: band.minY, width: gw, height: band.height))
        x += gw + gap
    }
    return rects
}

/// Per-frame memo for the graph's expensive layout. The whole layout is a pure
/// function of the input data + window size, but it was recomputed hundreds of times
/// per frame (every `bw`/`bh` access, every position-dictionary read in the hover
/// hit-test, etc.), which made scrolling and resizing lag badly. This caches each
/// heavy result and invalidates the lot whenever the layout signature changes, so a
/// frame computes the layout once. It's a reference type held in @State so mutating
/// its fields doesn't trigger a view update (only the data/size inputs do).
final class LayoutCache {
    var sig: Int = .min
    var forest: (childrenOf: [String: [AttachedDevice]], rootsByPort: [Int: [AttachedDevice]])?
    var slots: [Int: (center: CGFloat, width: CGFloat)]?
    var contentW: CGFloat?
    var contentH: CGFloat?
    var iface: [String: CGPoint]?
    var hwPort: [Int: CGPoint]?
    var dev: [String: CGPoint]?
    var gw: [String: CGPoint]?
    func clear() {
        forest = nil; slots = nil; contentW = nil; contentH = nil
        iface = nil; hwPort = nil; dev = nil; gw = nil
    }
}

// MARK: - GraphLayoutEngine (SwiftUI-free layout geometry)

/// The pure layout-geometry of the graph, lifted verbatim out of `NetworkGraphView`
/// so a future non-SwiftUI (web/SVG) renderer can reuse it. It reads only Foundation
/// model types + `ColorToken`; the SwiftUI view builds one per `body` evaluation and
/// delegates through thin forwarders. The shared `cache` (a class held in the view
/// @State) persists memoization across rebuilds, so behavior is unchanged.
struct GraphLayoutEngine {
    let interfaces:      [InterfaceInfo]
    let trafficStates:   [String: TrafficState]
    let routes:          [RouteEntry]
    let gateways:        [GatewayNode]
    let hardwarePorts:   [HardwarePort]
    let attachedDevices: [AttachedDevice]
    let egress:          EgressInfo?
    let systemPower:     SystemPower?
    let hideUnused:      Bool
    let viewSize:        CGSize
    let cache:           LayoutCache

    /// Signature of every input the layout depends on: window size + the identity and
    /// layout-affecting fields of each interface / device / port / gateway. When this
    /// changes, the layout memo is invalidated and recomputed once. Cheap (O(n) hashing)
    /// relative to the layout it guards.
    private var layoutSig: Int {
        var h = Hasher()
        h.combine(Int(viewSize.width)); h.combine(Int(viewSize.height)); h.combine(hideUnused)
        for i in visible {
            h.combine(i.id); h.combine(i.category.rawValue); h.combine(i.hasLink)
            h.combine(i.macAddress ?? "")
            h.combine(i.groupKey)   // captures displayName→isVirtualAdapter, which changes grouping
        }
        for d in attachedDevices {
            h.combine(d.id); h.combine(d.receptacle); h.combine(d.parentID ?? "")
            h.combine(d.kind.label); h.combine(d.interfaceBSD ?? "")
            h.combine(d.name)       // sibling sort tiebreak; a late-resolving USB name reorders chips
        }
        for p in hardwarePorts {
            h.combine(p.id); h.combine(p.isPhone)
            h.combine(p.childBSDNames.joined(separator: ",")); h.combine(p.physicalReceptacle ?? -999)
        }
        for g in gateways {
            h.combine(g.id); h.combine(g.isDefault); h.combine(g.isVPN)
            h.combine(g.reachableVia.joined(separator: ","))
            h.combine(g.vpnServer ?? ""); h.combine(g.vpnCarrier ?? "")  // VPN far-side + carrier drive the tier/pipe
        }
        h.combine(egress?.name ?? "")
        h.combine(systemPower != nil)   // battery slot presence adds/removes a Hardware-row slot
        return h.finalize()
    }

    /// Return the cached value for `kp`, computing (and caching) it once per signature.
    private func memo<T>(_ kp: ReferenceWritableKeyPath<LayoutCache, T?>, _ compute: () -> T) -> T {
        let sig = layoutSig
        if cache.sig != sig { cache.sig = sig; cache.clear() }
        if let cached = cache[keyPath: kp] { return cached }
        let value = compute()
        cache[keyPath: kp] = value
        return value
    }

    var visible: [InterfaceInfo] {
        hideUnused ? interfaces.filter { !$0.isHiddenWhenInactive(active: hasTraffic($0.id)) } : interfaces
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
    var physFreeVisible: [InterfaceInfo] {
        visible.filter { $0.effectiveLayer == "Physical" && !isAnchoredPhysical($0) }
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
        let byReceptacle = anchoredIfacesByReceptacle
        let spacing = anchoredSpacing
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
    var physicalUpperLaneCount: Int {
        spreadAnchored(anchoredPhysicalLayout(), minGap: 112).lanes
    }

    // MARK: - Band area geometry (everything right of the gateway sidebar)

    // Hardware-band slot sizing (shared by hwSlotLayout + contentWidth so they agree).
    private let hwMinSlotW: CGFloat = 110    // room for a port node + its label
    private let hwLeafSlotW: CGFloat = 92    // ideal width per device leaf
    // Horizontal gap between anchored Physical tiles sharing a receptacle. Shared by
    // anchoredPhysicalLayout (the spread) and the slot-width reservation below.
    private let anchoredSpacing: CGFloat = 112

    /// Minimum slot width that holds `n` anchored Physical tiles spread at
    /// `anchoredSpacing`. A port with several anchored interfaces (e.g. an iPhone's
    /// USB-tether channels) must reserve room for their spread, or the tiles overflow
    /// the slot and interleave with the neighbouring port's tiles — which collides
    /// their brackets. `hwSlotLayout` and `computeContentWidth` both fold this in so
    /// they stay in agreement. Geometry-free.
    private func anchoredSlotSpan(_ n: Int) -> CGFloat {
        n > 1 ? CGFloat(n - 1) * anchoredSpacing + hwLeafSlotW : hwMinSlotW
    }

    /// Anchored Physical interface ids grouped by the physical receptacle they belong
    /// to (port id, -1 for Wi-Fi, or a USB-network device's receptacle). Single source
    /// of truth for the anchored spread AND the slot-width reservation. Geometry-free.
    private var anchoredIfacesByReceptacle: [Int: [String]] {
        var byReceptacle: [Int: [String]] = [:]
        for iface in visible where iface.effectiveLayer == "Physical" && isAnchoredPhysical(iface) {
            if let port = portForBSD[iface.id] {
                byReceptacle[port, default: []].append(iface.id)
            } else if iface.id == wifiUplinkInterface {
                byReceptacle[-1, default: []].append(iface.id)
            } else if let dev = attachedDevices.first(where: { $0.interfaceBSD == iface.id }) {
                byReceptacle[dev.receptacle, default: []].append(iface.id)
            }
        }
        return byReceptacle
    }

    /// Natural (uncompressed) canvas width the graph wants. `bw` floors at this so the
    /// device tree and node rows keep comfortable spacing instead of scaling down until
    /// their fixed-size tiles crowd/overlap — a narrow window (or an iOS-sized screen)
    /// scrolls horizontally instead. Matches the slot/row widths the layouts use.
    private var contentWidth: CGFloat { memo(\.contentW, computeContentWidth) }
    private func computeContentWidth() -> CGFloat {
        let margin: CGFloat = 46
        let f = deviceForest
        func leaves(_ id: Int) -> Int {
            (f.rootsByPort[id] ?? []).map { leafCount($0, f.childrenOf) }.reduce(0, +)
        }
        let order = hwPortOrder
        let anchoredCounts = anchoredIfacesByReceptacle.mapValues { $0.count }
        let hwNatural = order.isEmpty ? 0
            : order.reduce(0) { $0 + max(hwMinSlotW, CGFloat(leaves($1)) * hwLeafSlotW,
                                         anchoredSlotSpan(anchoredCounts[$1] ?? 0)) } + margin * 2
        // Virtual band: two rows of ~112-wide node slots, sized from the row that actually
        // ends up WIDEST. Sizing from (total + 1) / 2 assumed a balanced split; the split is
        // on group boundaries, so one row routinely holds more than half the nodes.
        let vRows = virtualRows()
        let vWidest = vRows.map { row in
            let n = row.reduce(0) { $0 + $1.interfaces.count }
            return n == 0 ? CGFloat(0)
                          : CGFloat(n) * 112 + CGFloat(max(row.count - 1, 0)) * uniformGroupGap
        }.max() ?? 0
        let vNatural = vWidest == 0 ? 0 : vWidest + margin * 2
        // Physical free-adapter row.
        let pN = physFreeVisible.count
        let pNatural = pN == 0 ? 0 : CGFloat(pN) * 112 + margin * 2
        return max(hwNatural, max(vNatural, pNatural))
    }
    var bw: CGFloat { max(viewSize.width - gwColWidth, contentWidth) }
    var bh: CGFloat { max(viewSize.height, contentHeight) }

    private let deviceRowGap: CGFloat = 66   // > device chip height (52) so tree levels don't overlap
    private let deviceRowZig: CGFloat = 22   // per-row horizontal zigzag for single-file chains
    // Strip reserved at the top of the Virtual band for the VPN gateway chip, so it
    // doesn't collide with the tunnel rows. Shared by bandNeeds, virtualGroupLayout,
    // and gatewayPositions so they agree.
    private let vpnStripHeight: CGFloat = 92

    // MARK: - Device forest (USB hub → device hierarchy)

    /// The parent→children forest of attached devices: a device whose hub is
    /// present nests under it; everything else is a root on its hardware port.
    private var deviceForest: (childrenOf: [String: [AttachedDevice]],
                               rootsByPort: [Int: [AttachedDevice]]) {
        memo(\.forest, computeDeviceForest)
    }
    private func computeDeviceForest() -> (childrenOf: [String: [AttachedDevice]],
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
            if a.kind.label != b.kind.label { return a.kind.label < b.kind.label }
            switch a.name.localizedCaseInsensitiveCompare(b.name) {
            case .orderedAscending:  return true
            case .orderedDescending: return false
            case .orderedSame:       return a.id < b.id   // stable tiebreak (e.g. two identical joysticks)
            }
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

    /// Assign the Virtual-band subgroups to the two rows. THE single definition of the
    /// split: `virtualGroupLayout`, `virtualRowsUsed` and `computeContentWidth` all used to
    /// re-derive it, and the width calculation got it wrong — it assumed the two rows split
    /// the node count evenly, when the split is actually on GROUP boundaries. A first group
    /// larger than half (16 tunnels out of 22, say) therefore had the canvas sized for 11
    /// nodes while row 0 had to fit 16, and `uniformRects` compressed the per-node width
    /// below the drawn box, overlapping every chip in the row.
    func virtualRows() -> [[IfaceGroup]] {
        let groups = subgroups(layer: "Virtual", ifaces: visible)
        guard !groups.isEmpty else { return [[], []] }
        let total = groups.reduce(0) { $0 + $1.interfaces.count }
        let half  = (total + 1) / 2
        var rows: [[IfaceGroup]] = [[], []]
        var counts = [0, 0]
        for g in groups {
            let r = counts[0] < half ? 0 : 1
            rows[r].append(g); counts[r] += g.interfaces.count
        }
        return rows
    }

    /// Whether the Virtual band actually fills its second row, so it doesn't reserve
    /// height it won't use.
    private var virtualRowsUsed: Int {
        let rows = virtualRows()
        if rows[0].isEmpty && rows[1].isEmpty { return 0 }
        return rows[1].isEmpty ? 1 : 2
    }

    // MARK: - Content-driven band sizing

    /// Bands size themselves to the entities they must show: the Hardware band
    /// grows with the depth of the USB device tree; Physical/Virtual shrink to the
    /// number of rows actually in use. Heights are proportional shares of the area
    /// below the header, so the bands always fill the view without overlapping.
    /// Height each band needs to show its content without its fixed-size tiles
    /// overflowing (which would overlap the neighboring band). Drives both the
    /// proportional band fractions and the overall content height / scroll floor.
    /// True when anchored Physical interfaces (and thus their TB-port brackets) exist.
    private var hasAnchoredPhysical: Bool {
        visible.contains { $0.effectiveLayer == "Physical" && isAnchoredPhysical($0) }
    }
    /// Strip reserved at the top of the Physical band for the port bracket labels, so
    /// the interface tiles start below them instead of riding up over the brackets
    /// when the band has several rows (visible on constrained windows). Geometry-free.
    var physBracketInset: CGFloat { hasAnchoredPhysical ? 36 : 0 }

    private var bandNeeds: [(name: String, need: CGFloat)] {
        let depth = deviceForestDepth
        let deviceLevels = attachedDevices.isEmpty ? 0 : depth + 1
        let hwNeed = 96 + CGFloat(deviceLevels) * deviceRowGap + 24

        // Physical needs one row per anchored lane (stacked so tiles never overlap)
        // plus one for the free/grouped interfaces.
        let lanes = physicalUpperLaneCount
        let freeGroups = subgroups(layer: "Physical", ifaces: physFreeVisible).count
        let physRows = max(lanes + (freeGroups > 0 ? 1 : 0), 1)
        let physNeed = CGFloat(physRows) * 96 + 24 + physBracketInset

        // Data Link holds full interface tiles (bridge0, VLANs — 90 tall), so the band
        // must fit one, not just a label; otherwise the tile overflows into neighbors.
        let hasDL = visible.contains { $0.effectiveLayer == "Data Link" }
        let dlNeed: CGFloat = hasDL ? 118 : 26

        // Virtual holds the tunnel/loopback/system rows; reserve an extra strip at its
        // top for the VPN gateway chip, which pins above its tunnel (see gatewayPositions)
        // and would otherwise collide with the Data Link band above.
        let hasVPNgw = gateways.contains { $0.isVPN }
        let vNeed = CGFloat(max(virtualRowsUsed, 1)) * 118 + 20 + (hasVPNgw ? vpnStripHeight : 0)

        return [("Hardware", hwNeed), ("Physical", physNeed),
                ("Data Link", dlNeed), ("Virtual", vNeed)]
    }

    var bands: [LayerBand] {
        let needs = bandNeeds
        let total = needs.reduce(0) { $0 + $1.need }
        return needs.map { name, need in
            let s = bandStyles[name] ?? (.clear, "")
            return LayerBand(id: name, color: s.color, osiLabel: s.osi, heightFraction: need / total)
        }
    }

    /// True when an active VPN's far-side server has been resolved — the trigger for
    /// reserving the far-side tier and painting the concentrator node + pipe.
    private var hasVPNServer: Bool { gateways.contains { $0.isVPN && $0.vpnServer != nil } }
    /// Extra top inset above the Internet row: the far-side tier when a VPN server is
    /// present, else zero. Everything below shifts down by this and the canvas grows.
    private var farOffset: CGFloat { hasVPNServer ? farRowHeight : 0 }

    /// The graph's natural height: the (far tier +) header plus every band at its full
    /// need. `bh` never drops below this, so bands can't compress and spill tiles into
    /// each other — a short window scrolls (see the ScrollView in `body`) instead of
    /// overlapping. When the window is taller than this, the graph fills it.
    private var contentHeight: CGFloat { memo(\.contentH) { farOffset + headerHeight + bandNeeds.reduce(0) { $0 + $1.need } } }

    func bandRect(_ name: String) -> CGRect {
        let usable = max(bh - headerHeight - farOffset, 0)
        var y: CGFloat = headerHeight + farOffset
        for band in bands {
            let h = band.heightFraction * usable
            if band.name == name { return CGRect(x: 0, y: y, width: 0, height: h) }
            y += h
        }
        return .zero
    }

    // MARK: - Position maps (computed, not @State)

    var ifacePositions: [String: CGPoint] { memo(\.iface, computeIfacePositions) }
    private func computeIfacePositions() -> [String: CGPoint] {
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
        // Rows sit below the reserved bracket strip so tiles don't overlap the labels.
        let rowH       = max(physBand.height - physBracketInset, 1) / CGFloat(totalRows)
        func rowY(_ i: Int) -> CGFloat { physBand.minY + physBracketInset + rowH * (CGFloat(i) + 0.5) }

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
        for iface in visible.filter({ $0.effectiveLayer == "Data Link" }) {
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
    func virtualGroupLayout(w: CGFloat) -> [(group: IfaceGroup, rect: CGRect)] {
        let band = bandRect("Virtual")
        let rows = virtualRows()
        guard !(rows[0].isEmpty && rows[1].isEmpty) else { return [] }
        // Keep the tunnel rows below the strip reserved for the VPN gateway chip.
        let inset: CGFloat = gateways.contains { $0.isVPN } ? vpnStripHeight : 0
        let rowH = max(band.height - inset, 1) / 2
        var out: [(IfaceGroup, CGRect)] = []
        for r in 0..<2 {
            let rb = CGRect(x: 0, y: band.minY + inset + CGFloat(r) * rowH, width: 0, height: rowH)
            let rects = uniformRects(groups: rows[r], band: rb, w: w)
            for (i, g) in rows[r].enumerated() where i < rects.count { out.append((g, rects[i])) }
        }
        return out.map { (group: $0.0, rect: $0.1) }
    }

    /// Gateways are chips pinned to their host: default gateways sit in the top
    /// gateway tier above the column of the device/interface they live on; a VPN
    /// gateway pins just above its tunnel interface down in the Virtual row.
    var gatewayPositions: [String: CGPoint] { memo(\.gw, computeGatewayPositions) }
    private func computeGatewayPositions() -> [String: CGPoint] {
        guard bw > 0, bh > 0, !gateways.isEmpty else { return [:] }
        let tierY = farOffset + internetRowHeight + gwTierHeight / 2
        var result: [String: CGPoint] = [:]
        for gw in gateways {
            if gw.isVPN {
                if let tun = gw.reachableVia.first(where: { ifacePositions[$0] != nil }),
                   let p = ifacePositions[tun] {
                    // Pin the VPN gateway in the strip reserved at the TOP of the Virtual
                    // band (over its tunnel's column), so it clears the Data Link band
                    // above and the tunnel row below instead of overlapping them.
                    result[gw.id] = CGPoint(x: p.x, y: bandRect("Virtual").minY + vpnStripHeight / 2)
                }
            } else if let hx = gatewayHostX(gw) {
                // Nudge the gateway OFF its host's exact column: pinned dead-center above
                // the port/device it crowds the vertical chain (USB → port → GW stacks in
                // one narrow pile). Lean toward the canvas center — where the Internet node
                // sits — so the hop reads as a gentle curve and the tree pulls inward into
                // the open space. Clamped to stay on-canvas.
                let lean: CGFloat = 46
                let x = min(max(hx + (hx <= bw / 2 ? lean : -lean), 60), bw - 60)
                result[gw.id] = CGPoint(x: x, y: tierY)
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
    private var hwSlotLayout: [Int: (center: CGFloat, width: CGFloat)] { memo(\.slots, computeHwSlotLayout) }
    private func computeHwSlotLayout() -> [Int: (center: CGFloat, width: CGFloat)] {
        let order = hwPortOrder
        guard !order.isEmpty, bw > 0 else { return [:] }
        let f = deviceForest
        func leaves(_ id: Int) -> Int {
            (f.rootsByPort[id] ?? []).map { leafCount($0, f.childrenOf) }.reduce(0, +)
        }
        let minSlotW = hwMinSlotW     // room for a port node + its label
        let leafSlotW = hwLeafSlotW   // ideal width per device leaf
        let margin: CGFloat = 46
        let avail = max(bw - margin * 2, 1)
        let anchoredCounts = anchoredIfacesByReceptacle.mapValues { $0.count }
        var need: [Int: CGFloat] = [:]
        for id in order {
            need[id] = max(minSlotW, CGFloat(leaves(id)) * leafSlotW, anchoredSlotSpan(anchoredCounts[id] ?? 0))
        }
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

    var hwPortPositions: [Int: CGPoint] { memo(\.hwPort, computeHwPortPositions) }
    private func computeHwPortPositions() -> [Int: CGPoint] {
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
    var devicePositions: [String: CGPoint] { memo(\.dev, computeDevicePositions) }
    private func computeDevicePositions() -> [String: CGPoint] {
        guard bw > 0, bh > 0, !attachedDevices.isEmpty else { return [:] }
        let hw = hwPortPositions
        let slots = hwSlotLayout
        let f = deviceForest
        let pad: CGFloat = 8
        var result: [String: CGPoint] = [:]

        for (recep, roots) in f.rootsByPort {
            guard let base = hw[recep], let region = slots[recep] else { continue }
            // Already ordered by type-then-name in deviceForest; keep that order.
            let sorted = roots
            let leaves = max(sorted.map { leafCount($0, f.childrenOf) }.reduce(0, +), 1)
            let usable = max(region.width - pad * 2, 1)
            let slot = usable / CGFloat(leaves)
            let loX = region.center - region.width / 2 + 6
            let hiX = region.center + region.width / 2 - 6
            func clampX(_ x: CGFloat) -> CGFloat { min(max(x, loX), max(loX, hiX)) }

            var cursor = region.center - usable / 2
            // Clear the anchor above: its node is ~62 tall (half 31) and a device chip
            // ~52 (half 26), so the first row must sit ≥ ~57 below the anchor's center —
            // 52 left them touching (USB-network chip under a TB port, displays under the
            // Displays entity). 68 gives a comfortable gap.
            let topY = base.y + 68
            // Lay a subtree left-to-right; return the node's center x (midpoint of
            // its children's span). Depth-capped as cheap insurance against a
            // pathological registry (parentID is structurally acyclic, but still).
            func place(_ d: AttachedDevice, _ depth: Int, _ solo: Bool) -> CGFloat {
                let y = topY + CGFloat(min(depth, 24)) * deviceRowGap
                let kids = depth < 24 ? (f.childrenOf[d.id] ?? []) : []   // forest order (type, then name)
                // Zigzag a genuine SINGLE-FILE chain (a lone root whose every level has
                // exactly one child) left/right per row so it reads as a curve instead of
                // a rigid vertical pile. `solo` is propagated down (see below) so it stays
                // true ONLY for such a chain — an only-child that sits beside a sibling
                // subtree must NOT shift, or it collides with the sibling's leaves (a
                // single-child USB hub next to a multi-child one). Multi-child rows already
                // spread, so leave those centered. Applied to the STORED position only (the
                // returned x keeps the tidy-tree centering exact) and clamped, so a subtree
                // never leaves its lane.
                let dx = solo ? (depth % 2 == 0 ? deviceRowZig : -deviceRowZig) : 0
                if kids.isEmpty {
                    let x = cursor + slot / 2
                    cursor += slot
                    result[d.id] = CGPoint(x: clampX(x + dx), y: y)
                    return x
                }
                let xs = kids.map { place($0, depth + 1, solo && kids.count == 1) }
                let x = (xs.first! + xs.last!) / 2
                result[d.id] = CGPoint(x: clampX(x + dx), y: y)
                return x
            }
            for root in sorted { _ = place(root, 0, sorted.count == 1) }
        }
        return result
    }

    /// The egress ("Internet") node sits centered in the top row (below the far-side
    /// tier when a VPN concentrator is shown).
    var egressPosition: CGPoint? {
        guard egress != nil, bw > 0 else { return nil }
        return CGPoint(x: bw / 2, y: farOffset + internetRowHeight / 2)
    }

    /// Horizontal fan-out of the far-side tiles: when BOTH the concentrator and the
    /// "Direct" excludes node are shown they split to either side of the Internet's
    /// center column (a symmetric branch, like the displays entity fans downward). A
    /// single tile stays centered.
    private var farTileSpread: CGFloat { hasVPNExcludes ? min(92, max(0, bw / 2 - 58)) : 0 }

    /// The far-side VPN concentrator, painted BEYOND the Internet node in its own
    /// reserved top tier. Present only when an active VPN's server IP is resolved.
    var vpnServerPosition: CGPoint? {
        guard hasVPNServer, bw > 0 else { return nil }
        return CGPoint(x: bw / 2 - farTileSpread, y: farRowHeight / 2)
    }
    /// The resolved far-side server IP (the concentrator's public address), if any.
    var vpnServerID: String? { gateways.first { $0.isVPN && $0.vpnServer != nil }?.vpnServer }

    /// Split-tunnel EXCLUDE destinations: public routes pinned to the VPN's physical
    /// carrier (non-default, and not the concentrator host-pin) that bypass the tunnel
    /// and egress directly, unencrypted. Local/private subnet excludes are LAN geography
    /// (handled with the neighbor map), not this beyond-the-Internet contrast.
    var vpnExcludeRoutes: [RouteEntry] {
        guard let vpnGW = gateways.first(where: { $0.isVPN && $0.vpnServer != nil }),
              let carrier = vpnGW.vpnCarrier else { return [] }
        // Public routes on the carrier that bypass the tunnel — but NOT the VPN's own
        // static host-pins (concentrator/portal/DNS), which are encrypted infrastructure,
        // not user split-tunnel excludes (see isVPNInfraPin).
        return routes.filter {
            $0.interfaceName == carrier && !$0.isDefault
            && isPublicIPv4($0.destination) && !isVPNInfraPin($0)
        }
    }
    var hasVPNExcludes: Bool { !vpnExcludeRoutes.isEmpty }

    /// The "Direct" node — the public split-tunnel excludes — sits in the far tier
    /// beside the encrypted concentrator, reached by a plain (unencrypted) wire.
    var vpnExcludePosition: CGPoint? {
        guard hasVPNExcludes, bw > 0 else { return nil }
        return CGPoint(x: bw / 2 + farTileSpread, y: farRowHeight / 2)
    }

    /// Min distance from `p` to a quadratic Bézier, by sampling points along it.
    func distanceToCurve(_ p: CGPoint, _ a: CGPoint, _ c: CGPoint, _ b: CGPoint) -> CGFloat {
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

    func hitRect(_ c: CGPoint, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
    }

    /// All interface tiles sitting on a port's physical receptacle: its own child
    /// interfaces (TB-bridge members, iPhone channels) PLUS any device-provided
    /// interface (e.g. a dock's USB-Ethernet) attached to the same receptacle.
    /// Mirrors the `byReceptacle` grouping in `anchoredPhysicalLayout`, so the
    /// bracket spans every tile that layout placed under this port.
    func receptacleBSDs(_ port: HardwarePort) -> [String] {
        var ids = Set(port.childBSDNames)
        for dev in attachedDevices where dev.receptacle == port.id {
            if let bsd = dev.interfaceBSD { ids.insert(bsd) }
        }
        return Array(ids)
    }

    func portBracketLabel(_ p: HardwarePort) -> String { hardwarePortLabel(p) }

    /// The Thunderbolt-port brackets: for each receptacle, the horizontal span of the
    /// interface tiles it owns, plus its label. Pure geometry, so both renderers draw the
    /// same bracket — the SVG had no brackets at all, so a port owning several interfaces
    /// lost the grouping the SwiftUI graph shows.
    ///
    /// Only the TOP row of tiles is spanned: in a narrow window `spreadAnchored` can wrap a
    /// receptacle's tiles to a lower lane, and the bracket sits at the band top, so spanning
    /// a wrapped tile's x would float misleadingly above it.
    struct BracketSpan {
        let minX: CGFloat, maxX: CGFloat, y: CGFloat, label: String
    }

    func tbBracketSpans() -> [BracketSpan] {
        let bracketY = bandRect("Physical").minY + 26
        var out: [BracketSpan] = []
        for port in hardwarePorts {
            let pts = receptacleBSDs(port).compactMap { ifacePositions[$0] }
            guard let topY = pts.map({ $0.y }).min() else { continue }
            let xs = pts.filter { abs($0.y - topY) < 1 }.map { $0.x }
            guard !xs.isEmpty else { continue }
            out.append(BracketSpan(minX: (xs.min() ?? 0) - 46, maxX: (xs.max() ?? 0) + 46,
                                   y: bracketY, label: portBracketLabel(port)))
        }
        return out
    }

    /// Point on a quadratic Bézier at t = 0.5 — the visual middle of the wire.
    func curveMidpoint(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: 0.25 * a.x + 0.5 * c.x + 0.25 * b.x,
                y: 0.25 * a.y + 0.5 * c.y + 0.25 * b.y)
    }

    /// Control point for a connector's quadratic curve, bowed perpendicular to the
    /// line by a deterministic amount so collinear / parallel lines arc apart and
    /// stay individually legible instead of stacking on one path.
    func curveControl(_ line: ConnLine) -> CGPoint {
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
        // Split across statements deliberately: as one expression the type-checker times
        // out when Core is compiled as its own module (the Linux configuration), which
        // fails the build on a line that is trivially cheap at runtime.
        let saltX: CGFloat = line.from.x * 3 + line.to.x * 11
        let saltY: CGFloat = line.from.y * 7 + line.to.y * 17
        let salt = Int(saltX + saltY)
        let sign: CGFloat = (salt & 1 == 0) ? 1 : -1
        let bow = sign * min(26, len * 0.12) + line.laneBias
        return CGPoint(x: mx + nx * bow, y: my + ny * bow)
    }

    private func hasTraffic(_ name: String) -> Bool {
        let t = trafficStates[name]; return t?.rxActive == true || t?.txActive == true
    }

    // NOT memoized: this depends on trafficStates (rates, ant-crawl, emphasis), which
    // change every refresh and aren't in layoutSig. It's cheap now that the positions
    // it reads are memoized — just an O(n) assembly over cached points.
    func buildLines() -> [ConnLine] {
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
                        color: isDevice ? .link : .neutral,
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
                    color: .attach, hasTraffic: false, emphasized: true, style: .physical))
            }
            // Device chip → the interface it provides: a hard link that ant-crawls
            // only when there's traffic.
            if let bsd = dev.interfaceBSD, let chip = devPos[dev.id], let ifaceP = ifacePositions[bsd] {
                // interface → device chip, so the ant-crawl flows OUTBOUND (up).
                lines.append(ConnLine(from: ifaceP, to: chip, label: "",
                    color: .link, hasTraffic: hasTraffic(bsd), emphasized: true,
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
                color: .link, hasTraffic: false, emphasized: true, style: .physical))
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
                        color: .l2, hasTraffic: hasTraffic(member.id),
                        ifaceID: member.id))
                }
            }
        }

        // L1 → L2: VLAN → parent
        for iface in visible where iface.category == .vlan {
            if let parent = visible.first(where: { $0.category == .ethernet || $0.category == .bridge }),
               let f = ifacePositions[iface.id], let t = ifacePositions[parent.id] {
                lines.append(ConnLine(from: f, to: t, label: "VLAN",
                    color: .l2, hasTraffic: hasTraffic(iface.id),
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
                        color: .gatewayPrimary, hasTraffic: hasTraffic(tun.id),
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
                    color: gw.isVPN ? .gatewayVPN : (primary ? .gatewayPrimary : .gatewayOther),
                    hasTraffic: hasTraffic(ifn),
                    emphasized: primary && (gw.isVPN || gw.isDefault),
                    dominant: primary && (gw.id == domGwID || gw.id == domVpnID),
                    ifaceID: ifn.isEmpty ? nil : ifn))
            }
        }

        // The Wi-Fi interface (en0) connects up to its AP entity.
        if let wifi = wifiUplink, let wp = hwPortPositions[-1], let ifP = ifacePositions[wifi] {
            lines.append(ConnLine(from: ifP, to: wp, label: "",
                color: .neutral, hasTraffic: hasTraffic(wifi),
                style: .link, dominant: wifi == domIface,
                ifaceID: wifi, showRate: true))
        }

        // Each default gateway chip → the Internet node at the top.
        if let ep = egressPosition {
            for gw in gateways where gw.isDefault && !gw.isVPN {
                if let gp = gatewayPositions[gw.id] {
                    lines.append(ConnLine(from: gp, to: ep, label: "",
                        color: .egress, hasTraffic: gatewayActive(gw), emphasized: true,
                        dominant: gw.id == domGwID, ifaceID: gw.reachableVia.first))
                }
            }
        }

        // VPN gateway → the L1 interface it egresses through (its encrypted
        // traffic enters the physical stack there, then rides that interface out).
        if let vpnGW = gateways.first(where: { $0.isVPN }),
           let vP = gatewayPositions[vpnGW.id],
           // The encrypted outer packets egress through the VPN's REAL carrier (resolved
           // from the route to its server) — not necessarily the top-ranked physical
           // default. Fall back to the dominant physical interface if unresolved.
           let dIface = vpnGW.vpnCarrier ?? domIface, let to = ifacePositions[dIface] {
            lines.append(ConnLine(from: vP, to: to, label: "egress",
                color: .gatewayVPN, hasTraffic: gatewayActive(vpnGW), emphasized: true, dominant: true,
                ifaceID: dIface, encapsulated: true))
        }

        // Slice B: fold the VPN's full path into one continuous encrypted pipe and
        // carry it out past the Internet to the far-side concentrator. Every wire on
        // the interfaces the encrypted payload rides (its tunnel(s) + the physical
        // carrier) becomes encapsulated + VPN-blue, and a final hop crosses from the
        // Internet node to the server. Only fires when the server is resolved, so
        // non-VPN graphs and VPNs without a pinned concentrator are untouched.
        if let vpnGW = gateways.first(where: { $0.isVPN && $0.vpnServer != nil }) {
            var pipeIfaces = Set(vpnGW.reachableVia)
            if let c = vpnGW.vpnCarrier { pipeIfaces.insert(c) }
            lines = lines.map { line in
                guard let ifn = line.ifaceID, pipeIfaces.contains(ifn) else { return line }
                var l = line
                l.encapsulated = true
                l.color = .gatewayVPN
                return l
            }
            if let ep = egressPosition, let sp = vpnServerPosition {
                lines.append(ConnLine(from: ep, to: sp, label: "",
                    color: .gatewayVPN, hasTraffic: gatewayActive(vpnGW), emphasized: true,
                    dominant: true, encapsulated: true))
            }
            // Unencrypted (non-tunnel) egress, traced ALONGSIDE the encrypted pipe: the
            // same physical carrier hops (interface → USB/TB adapter → LAN gateway) carry
            // direct traffic too, so draw a parallel amber strand up the carrier. Without
            // public excludes it terminates at the LAN gateway (local reach only); WITH
            // excludes it continues THROUGH the Internet out to the Direct destinations
            // (which are public, so the split is at the Internet, never the LAN gateway).
            // `laneBias` bows it perpendicular so it runs beside the blue pipe, sharing
            // each node so there's no kink. Static — we only have per-interface counters,
            // not per-subnet (per-subnet ant-crawl is a permissioned stretch goal).
            if let carrier = vpnGW.vpnCarrier {
                let lane: CGFloat = 22
                let carrierP = ifacePositions[carrier]
                // The hardware entity the carrier egresses through — the Wi-Fi AP chip, a
                // USB adapter, or a TB port — resolved the SAME way the blue pipe's own
                // hop is, so the strands stay parallel on every uplink type. (nil-equal to
                // the interface means there's no distinct chip → that hop is skipped.)
                let hubP = hostAnchorForInterface(carrier)
                // Anchor to the gateway on the CARRIER's own path — resolveVPNPaths' carrier
                // isn't necessarily the top-service-order default, so the strand must reach
                // the gateway that actually routes this uplink (fall back to the default).
                let carrierGW = gateways.first { !$0.isVPN && $0.reachableVia.contains(carrier) } ?? physDefault
                let gwP = carrierGW.flatMap { gatewayPositions[$0.id] }
                func amber(_ a: CGPoint?, _ b: CGPoint?, _ bias: CGFloat) {
                    guard let a, let b, a != b else { return }
                    lines.append(ConnLine(from: a, to: b, label: "", color: .split,
                        hasTraffic: false, emphasized: true, style: .data, laneBias: bias))
                }
                amber(carrierP, hubP, lane)
                amber(hubP ?? carrierP, gwP, lane)
                if hasVPNExcludes, let xp = vpnExcludePosition {
                    amber(gwP ?? hubP ?? carrierP, egressPosition, lane)
                    amber(egressPosition, xp, 0)
                }
            }
        }

        return lines
    }

    /// True when any interface that reaches this gateway has live traffic.
    private func gatewayActive(_ gw: GatewayNode) -> Bool {
        gw.reachableVia.contains { hasTraffic($0) }
    }
}

import Foundation

// The presentation payload for the web UI: every table cell already formatted, masked and
// filtered by the SAME Swift helpers the SwiftUI app and the TUI use.
//
// Why this exists. The browser used to receive the raw TopologySnapshot and rebuild the
// tables in JavaScript, which meant reimplementing `speedLabel`, `connectionLabel`,
// `classLabel`, `idLabel`, the byte/rate formatters and the route classifier — six
// formatters, each of which had drifted from its Swift original:
//
//   * Speed read `detail`, which only displays have, so every USB device showed "—" even
//     though `linkSpeedBps` was right there in the JSON.
//   * Bus read `connection` ("USB") instead of the negotiated `usbVersion` ("USB 3.2").
//   * Type printed the raw enum case ("gamecontroller") rather than `kind.label`.
//   * The rate formatter used a different idle threshold and a different Mbps precision, so
//     the same link read differently in the browser than in the app.
//   * The route classifier used its own private-range regex, filing 169.254/224.0 routes
//     under the alarming heading "Direct — split-tunnel (unencrypted)".
//
// Keeping the formatting in Swift removes the whole class of drift, and it keeps
// `/snapshot.json` a clean, unadorned `--dump-json` contract.
//
// It also makes privacy honest: masking happens HERE, before the bytes leave the process,
// so a `serve` instance with privacy on never puts a real address on the wire.

/// One already-rendered table row: an ordered list of cells plus optional row metadata.
public struct UIRow: Encodable, Sendable {
    public var cells: [String]
    /// Nesting depth for the device tree (0 = root); the browser indents by it.
    public var depth: Int?
    /// Link state, for the coloured dot in the Interfaces table.
    public var state: String?
    /// True while this interface is passing traffic — drives the rate-cell highlight.
    public var active: Bool?
    /// The interface an SVG wire carries, so the browser can animate the matching wire.
    public var iface: String?
}

public struct UISection: Encodable, Sendable {
    public var title: String
    public var columns: [String]
    public var rows: [UIRow]
}

public struct UIPayload: Encodable, Sendable {
    public var header: String
    public var interfaces: UISection
    public var routes: [UISection]
    public var devices: [UISection]
    public var dns: [UISection]
    public var dnsBanner: String?
    /// Interface ids currently passing traffic — the browser toggles wire animation on these.
    public var activeInterfaces: [String]
    public var deviceEmptyMessage: String?
}

/// Build the whole payload. `rates` must already have been updated with this snapshot.
public func buildUIPayload(_ s: TopologySnapshot, rates: TrafficRateDeriver,
                           privacy: Bool, hideInactive: Bool) -> UIPayload {
    let ifaces = s.interfaces.filter {
        guard hideInactive else { return true }
        return !$0.isHiddenWhenInactive(active: rates.isActive($0.id))
    }

    let up = s.interfaces.filter { $0.linkState == .up }.count
    var headerBits: [String] = []
    if !s.machineModel.isEmpty { headerBits.append(s.machineModel) }
    if let e = s.egress {
        headerBits.append("egress: \(e.viaInterface) (\(maskNetworkName(e.displayName, privacy)))")
    } else {
        headerBits.append("egress: —")
    }
    headerBits.append("\(up)/\(s.interfaces.count) up")
    if hideInactive { headerBits.append("showing \(ifaces.count)") }
    if let p = s.systemPower?.label { headerBits.append(p) }

    return UIPayload(
        header: headerBits.joined(separator: "  ·  "),
        interfaces: interfacesSection(s, ifaces, rates, privacy),
        routes: routeSections(s, privacy),
        devices: deviceSections(s, privacy),
        dns: dnsSections(s, privacy),
        dnsBanner: dnsBanner(s, privacy),
        activeInterfaces: ifaces.filter { rates.isActive($0.id) }.map(\.id),
        deviceEmptyMessage: s.attachedDevices.isEmpty ? deviceEmptyText() : nil)
}

private func deviceEmptyText() -> String {
    // Platform-neutral now that the Linux collectors have shipped. The old Linux wording
    // ("collectors arrive in a later update") turned a correct "nothing is plugged in" into
    // a missing-feature notice, and made a real collector failure indistinguishable from an
    // empty machine.
    "No external devices detected. USB peripherals, hubs/docks and external displays appear here when connected."
}

// MARK: - Interfaces

private func interfacesSection(_ s: TopologySnapshot, _ ifaces: [InterfaceInfo],
                               _ rates: TrafficRateDeriver, _ privacy: Bool) -> UISection {
    // An interface provided by a USB adapter reads as that adapter, matching the app.
    let providedBy = Dictionary(
        s.attachedDevices.compactMap { d in d.interfaceBSD.map { ($0, d.name) } },
        uniquingKeysWith: { a, _ in a })

    let egressIface = s.egress?.viaInterface
    let rows = ifaces.map { i -> UIRow in
        let desc = providedBy[i.id] ?? i.displayName ?? i.subtitleLabel
        let st = rates.state(for: i.id)
        return UIRow(
            cells: [
                // Star the primary egress, matching the app and the TUI.
                i.id == egressIface ? "★ \(i.id)" : i.id,
                i.category.rawValue,
                maskAddresses(desc, privacy),
                i.ipv4Addresses.isEmpty ? "—"
                    : maskAddresses(i.ipv4Addresses.joined(separator: ", "), privacy),
                maskAddresses(i.macAddress ?? "—", privacy),
                String(i.mtu),
                i.formattedSpeed ?? "—",
                formatRate(rates.rxRate(for: i.id)) ?? "—",
                formatRate(rates.txRate(for: i.id)) ?? "—",
                formatByteCount(i.rxBytes),
                formatByteCount(i.txBytes),
            ],
            depth: nil,
            state: i.linkState == .up ? "up" : (i.linkState == .down ? "down" : "unknown"),
            active: st.rxActive || st.txActive,
            iface: i.id)
    }
    return UISection(
        title: "",
        // "Hardware Port / Description" and "Speed" were missing from the browser table
        // even though both fields were already in the JSON.
        columns: ["", "Interface", "Type", "Description", "IPv4", "MAC", "MTU",
                  "Speed", "RX/s", "TX/s", "RX", "TX"],
        rows: rows)
}

// MARK: - Routes

private func routeSections(_ s: TopologySnapshot, _ privacy: Bool) -> [UISection] {
    // "Priority" covers both platforms: Linux ranks by route metric, macOS has no metric at
    // all and ranks by network-service order. Lower wins either way, and the two can't both
    // be present, so one column carries whichever the platform has.
    let columns = ["Destination", "Gateway", "Netmask", "Interface", "Flags", "Priority"]
    // Classified in SWIFT, on the UNMASKED data, with the shared classifier. Doing it in JS
    // over masked destinations would have refiled every 192.168/172.16 LAN route as
    // "unencrypted split-tunnel" the moment privacy was switched on, because "192.x.x.x" no
    // longer matches a private-range test.
    let g = classifyRoutes(s.routes, gateways: s.gateways)
    // Only the winning default is starred — see primaryDefaultRouteID.
    let primaryID = primaryDefaultRouteID(s.routes, egress: s.egress)
    func rows(_ list: [RouteEntry]) -> [UIRow] {
        list.sorted { routeSortKey($0.destination) < routeSortKey($1.destination) }
            .map { r in
                UIRow(cells: [
                    maskAddresses(r.destination, privacy) + (r.id == primaryID ? " ✦" : ""),
                    maskAddresses(r.gateway.isEmpty ? "—" : r.gateway, privacy),
                    r.netmask ?? "—",     // a netmask describes the prefix, not the host
                    r.interfaceName,
                    r.flags,
                    r.metric.map(String.init)
                        ?? s.serviceRank[r.interfaceName].map { "\($0 + 1)" } ?? "—",
                ], depth: nil, state: nil, active: nil, iface: nil)
            }
    }
    return [("Direct — split-tunnel (unencrypted)", g.direct),
            ("Encrypted — VPN tunnel", g.encrypted),
            ("Local", g.local)]
        .filter { !$0.1.isEmpty }
        .map { UISection(title: $0.0, columns: columns, rows: rows($0.1)) }
}

// MARK: - Devices

private func deviceSections(_ s: TopologySnapshot, _ privacy: Bool) -> [UISection] {
    guard !s.attachedDevices.isEmpty else { return [] }
    let columns = ["Device", "Type", "Vendor", "Bus", "Speed", "Class", "VID:PID", "Port"]

    // Same dangling-parent guard the app and the layout engine use: a child whose parent
    // isn't in the snapshot is still a root, rather than vanishing from the table.
    let byId = Dictionary(s.attachedDevices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let children = Dictionary(grouping: s.attachedDevices.filter {
        guard let pid = $0.parentID else { return false }
        return byId[pid] != nil
    }, by: { $0.parentID! })
    func byName(_ a: AttachedDevice, _ b: AttachedDevice) -> Bool {
        a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    var rows: [UIRow] = []
    func walk(_ d: AttachedDevice, _ depth: Int) {
        let name = maskAddresses(d.name, privacy)
            + (d.interfaceBSD.map { " → \($0)" } ?? "")
        rows.append(UIRow(cells: [
            // idLabel is the serial for anything without a vendor:product pair — a Bluetooth
            // MAC or an EDID monitor serial — so it has to be masked like any other address.
            name, d.kind.label, d.vendorName ?? "—", d.connectionLabel, d.speedLabel,
            d.classLabel, privacy ? "•••" : d.idLabel, devicePortLabel(d, s.hardwarePorts),
        ], depth: depth, state: nil, active: nil, iface: nil))
        for kid in (children[d.id] ?? []).sorted(by: byName) { walk(kid, depth + 1) }
    }
    let roots = s.attachedDevices.filter { $0.parentID == nil || byId[$0.parentID!] == nil }
    for root in roots.sorted(by: {
        $0.receptacle != $1.receptacle ? $0.receptacle < $1.receptacle : byName($0, $1)
    }) { walk(root, 0) }

    return [UISection(title: "", columns: columns, rows: rows)]
}

// MARK: - DNS

private func dnsBanner(_ s: TopologySnapshot, _ privacy: Bool) -> String? {
    guard let g = s.dnsConfigs.first(where: { $0.isGlobal }) else { return nil }
    var out = "Active resolvers: "
        + g.servers.map { maskAddresses($0, privacy) }.joined(separator: "  ")
    if let ifn = g.interfaceName { out += "   via \(ifn)" }
    if !g.searchDomains.isEmpty {
        out += "   search: " + maskDomainList(g.searchDomains, privacy, separator: " ")
    }
    return out
}

private func dnsSections(_ s: TopologySnapshot, _ privacy: Bool) -> [UISection] {
    let scoped = s.dnsConfigs.filter { !$0.isGlobal }
    guard !scoped.isEmpty else { return [] }
    let rows = scoped.map { c -> UIRow in
        // maskScopeLabel only handles a user-named service. The Linux DNS collector appends
        // the live resolver ("enp0s1  (using 192.168.64.1)"), so the label needs address
        // masking too or privacy mode leaks the very address it redacts one column over.
        var scope = maskAddresses(maskScopeLabel(c.scopeLabel, interfaceName: c.interfaceName,
                                                 userNamed: c.userNamedScope, privacy), privacy)
        // The OS primary is starred, so a VPN winning over the physical uplinks is visible —
        // the browser table showed no primary marker and no split-DNS scoping at all.
        if c.isPrimary { scope = "★ " + scope }
        return UIRow(cells: [
            scope,
            c.interfaceName ?? "—",
            c.servers.map { maskAddresses($0, privacy) }.joined(separator: "  "),
            maskDomainList(c.searchDomains, privacy),
            c.isSupplemental ? maskDomainList(c.matchDomains, privacy) : "—",
        ], depth: nil, state: nil, active: nil, iface: nil)
    }
    return [UISection(title: "",
                      columns: ["Scope", "Interface", "Resolvers", "Search", "Split-DNS"],
                      rows: rows)]
}

// MARK: - Snapshot masking (for /snapshot.json)

/// Apply privacy masking and the hide-inactive filter to a snapshot before it is encoded, so
/// `serve` never puts unmasked addresses on the wire when privacy is on.
public func redactedSnapshot(_ s: TopologySnapshot, rates: TrafficRateDeriver,
                             privacy: Bool, hideInactive: Bool) -> TopologySnapshot {
    var out = s
    if hideInactive {
        out.interfaces = s.interfaces.filter {
            !$0.isHiddenWhenInactive(active: rates.isActive($0.id))
        }
    }
    guard privacy else { return out }
    out.interfaces = out.interfaces.map { i in
        var i = i
        i.ipv4Addresses = i.ipv4Addresses.map { maskAddresses($0, true) }
        i.ipv6Addresses = i.ipv6Addresses.map { maskAddresses($0, true) }
        i.macAddress = i.macAddress.map { maskAddresses($0, true) }
        return i
    }
    out.routes = out.routes.map { r in
        var r = r
        r.destination = maskAddresses(r.destination, true)
        r.gateway = maskAddresses(r.gateway, true)
        return r
    }
    // GatewayNode.id is the gateway address and is a `let` (it's the Identifiable key), so
    // the masked copy is rebuilt rather than mutated in place.
    out.gateways = out.gateways.map { g in
        var m = GatewayNode(id: maskAddresses(g.id, true), isDefault: g.isDefault,
                            reachableVia: g.reachableVia, isVPN: g.isVPN)
        m.networkName = g.networkName.map { maskNetworkName($0, true) }
        m.precedence = g.precedence
        m.vpnCarrier = g.vpnCarrier
        m.vpnServer = g.vpnServer.map { maskAddresses($0, true) }
        return m
    }
    out.egress = out.egress.map { e in
        var e = e
        e.name = e.name.map { maskNetworkName($0, true) }
        return e
    }
    out.dnsConfigs = out.dnsConfigs.map { c in
        var c = c
        c.servers = c.servers.map { maskAddresses($0, true) }
        c.searchDomains = c.searchDomains.isEmpty ? [] : ["••• (\(c.searchDomains.count) hidden)"]
        c.matchDomains = c.matchDomains.isEmpty ? [] : ["••• (\(c.matchDomains.count) hidden)"]
        // domainName names the employer's network just as squarely as the search list does;
        // redacting one and not the other defeats the point.
        if c.domainName != nil { c.domainName = "•••" }
        if c.userNamedScope { c.scopeLabel = c.interfaceName ?? "(service)" }
        return c
    }
    // AttachedDevice.id embeds the Bluetooth address ("bt-14-c2-13-ee-38-3a"), and `id` is a
    // `let`, so the masked copy has to be rebuilt rather than mutated. Masking only `serial`
    // left the same address in the id on /snapshot.json.
    // The Bluetooth id is "bt-14-c2-13-ee-38-3a", and maskAddresses deliberately leaves the
    // hyphen form alone (that is what keeps Linux and macOS rendering identically), so
    // running the id through it is a NO-OP and the address stayed in the JSON. Replace the
    // whole id with a positional one: it only has to be unique within this response.
    out.attachedDevices = out.attachedDevices.enumerated().map { (i, d) in
        let maskedID = d.id.hasPrefix("bt-") ? "bt-\(i)" : maskAddresses(d.id, true)
        var m = AttachedDevice(id: maskedID, name: d.name,
                               receptacle: d.receptacle, kind: d.kind)
        m.interfaceBSD = d.interfaceBSD
        m.parentID = d.parentID.map { maskAddresses($0, true) }
        m.vendorName = d.vendorName
        m.vendorID = d.vendorID
        m.productID = d.productID
        m.serial = d.serial.map { _ in "•••" }
        m.classCode = d.classCode
        m.usbVersion = d.usbVersion
        m.linkSpeedBps = d.linkSpeedBps
        m.detail = d.detail
        m.connection = d.connection
        m.batteryPercent = d.batteryPercent
        m.capacityBytes = d.capacityBytes
        return m
    }
    return out
}

import Foundation

// MARK: - Portable network normalization

// Pure transforms over the already-normalized model (RouteEntry / InterfaceInfo →
// GatewayNode / EgressInfo). No platform APIs — a Linux collector reuses these as-is.
// (BSD-name → InterfaceCategory classification stays platform-side: it decodes macOS
// interface-name prefixes, which differ on Linux.)

/// The machine's egress: the physical (non-tunnel) default route's interface and kind.
/// The network name (Wi-Fi SSID) is attached by the caller — it comes from a platform
/// API (CoreWLAN on macOS) — so this transform stays pure.
func computeEgress(routes: [RouteEntry], interfaces: [InterfaceInfo]) -> EgressInfo? {
    // The physical default route (not a tunnel) is the real egress.
    guard let r = routes.first(where: {
        $0.isDefault && !$0.interfaceName.isEmpty
        && !$0.interfaceName.hasPrefix("utun") && !$0.interfaceName.hasPrefix("ipsec")
    }) else { return nil }

    let ifname = r.interfaceName
    let iface  = interfaces.first { $0.id == ifname }
    let kind: EgressInfo.Kind
    switch iface?.category {
    case .wifi:                   kind = .wifi
    case .cellular:               kind = .cellular
    case .ethernet, .thunderbolt: kind = .wired
    default:                      kind = .other
    }
    return EgressInfo(viaInterface: ifname, kind: kind, name: nil)
}

/// Build the gateway nodes from the routing table: dedup by IP, flag VPN tunnels, and
/// rank each gateway's uplinks + the default-gateway precedence by the caller-supplied
/// `rank` (macOS network service order; a Linux collector passes a route-metric rank).
func buildGatewayNodes(from routes: [RouteEntry], interfaces: [InterfaceInfo], rank: [String: Int]) -> [GatewayNode] {
    // Collect all IPs assigned to local interfaces so we don't re-show them as gateways
    let localIPs = Set(interfaces.flatMap { $0.ipv4Addresses })

    var byIP: [String: GatewayNode] = [:]
    // Names of tunnel/VPN interfaces, so we can flag VPN gateways.
    let tunnelIfaces = Set(interfaces.filter { $0.category == .tunnel }.map { $0.id })

    for route in routes {
        let gw = route.gateway
        // Skip empty, loopback, and non-IPv4 (link-local IPv6, etc.)
        guard !gw.isEmpty, gw != "0.0.0.0", gw != "127.0.0.1" else { continue }
        guard gw.contains(".") else { continue }
        // Normally skip gateways that are one of our own interface IPs — BUT a
        // point-to-point VPN tunnel lists its own local address as the default
        // gateway, and that genuinely IS the VPN's egress. Keep those.
        if localIPs.contains(gw) && !route.isDefault { continue }

        if byIP[gw] == nil {
            byIP[gw] = GatewayNode(id: gw, isDefault: false, reachableVia: [])
        }
        if route.isDefault { byIP[gw]?.isDefault = true }
        if tunnelIfaces.contains(route.interfaceName) { byIP[gw]?.isVPN = true }
        if !route.interfaceName.isEmpty,
           !(byIP[gw]?.reachableVia.contains(route.interfaceName) ?? false) {
            byIP[gw]?.reachableVia.append(route.interfaceName)
        }
    }
    // Order each gateway's interfaces by the caller-supplied `rank` — the macOS
    // network SERVICE ORDER (System Settings drag-list; macOS exposes no numeric
    // route metric). A Linux collector will pass a route-metric-derived rank
    // instead, so a gateway shared by several uplinks anchors to whichever wins.
    for (ip, var node) in byIP {
        node.reachableVia.sort { (rank[$0] ?? Int.max) < (rank[$1] ?? Int.max) }
        byIP[ip] = node
    }

    // Precedence among DEFAULT gateways: VPN tunnels (which capture 0.0.0.0/0)
    // first, then physical defaults ranked by their best interface's service
    // order. So GW #1 is the active uplink and the VPN egresses through it.
    func bestRank(_ id: String) -> Int {
        (byIP[id]?.reachableVia.compactMap { rank[$0] }.min()) ?? Int.max
    }
    let vpnDefaults  = byIP.values.filter { $0.isDefault &&  $0.isVPN }.map(\.id).sorted()
    let physDefaults = byIP.values.filter { $0.isDefault && !$0.isVPN }.map(\.id)
        .sorted { bestRank($0) != bestRank($1) ? bestRank($0) < bestRank($1) : $0 < $1 }
    for (i, ip) in (vpnDefaults + physDefaults).enumerated() { byIP[ip]?.precedence = i + 1 }

    // Sort: by precedence (winning default first), then non-defaults by IP.
    return Array(byIP.values).sorted {
        switch ($0.precedence, $1.precedence) {
        case let (a?, b?): return a < b
        case (_?, nil):    return true
        case (nil, _?):    return false
        default:           return $0.id < $1.id
        }
    }
}

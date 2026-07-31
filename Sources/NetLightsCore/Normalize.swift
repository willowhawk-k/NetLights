import Foundation

// MARK: - Portable network normalization

// Pure transforms over the already-normalized model (RouteEntry / InterfaceInfo →
// GatewayNode / EgressInfo). No platform APIs — a Linux collector reuses these as-is.
// (BSD-name → InterfaceCategory classification stays platform-side: it decodes macOS
// interface-name prefixes, which differ on Linux.)

/// The machine's egress: the physical (non-tunnel) default route's interface and kind.
/// The network name (Wi-Fi SSID) is attached by the caller — it comes from a platform
/// API (CoreWLAN on macOS) — so this transform stays pure.
public func computeEgress(routes: [RouteEntry], interfaces: [InterfaceInfo]) -> EgressInfo? {
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

/// Whether an IPv4 string is a routable public address (not RFC1918 / loopback /
/// link-local / multicast / reserved / unspecified).
public func isPublicIPv4(_ ip: String) -> Bool {
    let p = ip.split(separator: ".").compactMap { Int($0) }
    guard p.count == 4, p.allSatisfy({ (0...255).contains($0) }) else { return false }
    switch (p[0], p[1]) {
    case (10, _), (127, _), (0, _):      return false
    case (172, 16...31):                 return false
    case (192, 168):                     return false
    case (169, 254):                     return false
    case (224...255, _):                 return false   // multicast + reserved
    default:                             return true
    }
}

/// A static HOST route (flags H+S) to a public IP — the signature a VPN client uses to
/// pin its concentrator/portal/gateway on the physical carrier. These carry the encrypted
/// OUTER packets (VPN infrastructure), NOT user split-tunnel excludes, so the "Direct"
/// (unencrypted) bucket must never claim them.
public func isVPNInfraPin(_ r: RouteEntry) -> Bool {
    r.flags.contains("H") && r.flags.contains("S") && isPublicIPv4(r.destination)
}

/// Resolve each VPN gateway's real underlay carrier + server endpoint from the routing
/// table. A VPN client pins its concentrator with a STATIC HOST route (flags H+S) to a
/// public IP via a PHYSICAL (non-tunnel) interface, so the encrypted outer packets reach
/// the server without looping back into the tunnel. That route's interface is the carrier
/// the encrypted traffic actually egresses through — which is NOT necessarily the
/// top-service-ranked physical default — and its destination is the server's public IP.
public func resolveVPNPaths(_ gateways: [GatewayNode], routes: [RouteEntry]) -> [GatewayNode] {
    let serverRoutes = routes.filter {
        $0.flags.contains("H") && $0.flags.contains("S")
        && !$0.interfaceName.isEmpty
        && !$0.interfaceName.hasPrefix("utun") && !$0.interfaceName.hasPrefix("ipsec")
        && isPublicIPv4($0.destination)
    }
    // Several static host-pins can ride the carrier (concentrator + portal / DNS / a
    // failover cluster). From the route table alone we can't tell which is THE
    // concentrator, so pick deterministically (stable across refreshes) rather than
    // kernel-order-arbitrary. Whichever is chosen, none of these H+S pins is ever
    // mislabeled as an unencrypted "Direct" exclude (see isVPNInfraPin).
    guard let server = serverRoutes.sorted(by: {
        $0.interfaceName != $1.interfaceName ? $0.interfaceName < $1.interfaceName
                                             : $0.destination < $1.destination
    }).first else { return gateways }
    // v1: with one active VPN, assign the pinned concentrator to the VPN gateway(s).
    // Per-tunnel correlation for multiple simultaneous VPNs is a refinement.
    return gateways.map { gw in
        guard gw.isVPN else { return gw }
        var g = gw
        g.vpnServer  = server.destination
        g.vpnCarrier = server.interfaceName
        return g
    }
}

/// Build the gateway nodes from the routing table: dedup by IP, flag VPN tunnels, and
/// rank each gateway's uplinks + the default-gateway precedence by the caller-supplied
/// `rank` (macOS network service order; a Linux collector passes a route-metric rank).
public func buildGatewayNodes(from routes: [RouteEntry], interfaces: [InterfaceInfo], rank: [String: Int]) -> [GatewayNode] {
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

// MARK: - Route classification (Routes view grouping)

/// Split the routing table into the buckets the Routes view groups by: split-tunnel
/// EXCLUDES that egress directly, unencrypted (`direct`); routes carried over the VPN
/// tunnel (`encrypted`); and everything else — local subnets, connected & system routes
/// (`local`). With no active VPN, everything lands in `local`. `direct`/`encrypted`
/// mirror the graph's own VPN path classification, so the two views agree.
public func classifyRoutes(_ routes: [RouteEntry], gateways: [GatewayNode])
    -> (direct: [RouteEntry], encrypted: [RouteEntry], local: [RouteEntry]) {
    let vpnGW = gateways.first { $0.isVPN && $0.vpnServer != nil }
    let tunnels = Set(gateways.filter { $0.isVPN }.flatMap { $0.reachableVia })
    var direct: [RouteEntry] = [], encrypted: [RouteEntry] = [], local: [RouteEntry] = []
    for r in routes {
        if tunnels.contains(r.interfaceName) {
            encrypted.append(r)
        } else if let gw = vpnGW, let carrier = gw.vpnCarrier,
                  r.interfaceName == carrier, !r.isDefault,
                  isPublicIPv4(r.destination), !isVPNInfraPin(r) {
            direct.append(r)
        } else {
            local.append(r)
        }
    }
    return (direct, encrypted, local)
}

/// Numeric ordering key for a route destination: "default" / 0.0.0.0 first, then by the
/// IPv4 address as a 32-bit number (10.x < 172.x < 192.x); non-IPv4 last, by string.
public func routeSortKey(_ destination: String) -> (UInt32, String) {
    if destination == "default" || destination == "0.0.0.0" { return (0, "") }
    let p = destination.split(separator: ".").compactMap { UInt32($0) }
    if p.count == 4, p.allSatisfy({ $0 <= 255 }) {
        return (p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3], "")
    }
    return (UInt32.max, destination)
}

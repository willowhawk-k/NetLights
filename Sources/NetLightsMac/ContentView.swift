import SwiftUI

struct ContentView: View {
    @ObservedObject var monitor: NetworkMonitor
    @State private var selectedTab: Tab = .graph
    @State private var hideUnused: Bool = false
    @State private var privacy: Bool = false
    @State private var routesSorted: Bool = false   // Routes tab: flat numeric sort vs grouped sections
    @State private var showExternalIP = false       // external-IP reveal popover

    enum Tab: String, CaseIterable {
        case graph      = "Graph"
        case routes     = "Routes"
        case interfaces = "Interfaces"
        case devices    = "Devices"
        case dns        = "DNS"
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            switch selectedTab {
            case .graph:
                NetworkGraphView(
                    interfaces: monitor.interfaces,
                    trafficStates: monitor.trafficStates,
                    routes: monitor.routes,
                    gateways: monitor.gateways,
                    hardwarePorts: monitor.hardwarePorts,
                    attachedDevices: monitor.attachedDevices,
                    egress: monitor.egress,
                    systemPower: monitor.systemPower,
                    hideUnused: hideUnused
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .routes:
                routesTable

            case .interfaces:
                interfaceTable

            case .devices:
                devicesTable

            case .dns:
                dnsView
            }

            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.privacyMode, privacy)
        // The monitor is app-scoped (owned by NetLightsApp), so start it once and
        // let it run for the app's lifetime — don't stop it on window close, or
        // closing one window would freeze polling/menu state for the others.
        .onAppear { monitor.start() }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            AppIconView()
                .frame(width: 24, height: 24)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            Text("NetLights")
                .font(.headline)

            Spacer()

            Picker("View", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 430)

            Spacer()

            // Hide-unused toggle — affects graph and interface table
            Toggle(isOn: $hideUnused) {
                Label("Hide inactive", systemImage: "eye.slash")
                    .font(.callout)
            }
            .toggleStyle(.button)
            .help("Hide interfaces with no IP address and no traffic (e.g. un-used utun ports)")

            // Privacy: mask IP / MAC addresses for screenshots & screen-sharing
            Toggle(isOn: $privacy) {
                Label("Privacy", systemImage: privacy ? "eye.slash.circle.fill" : "eye.slash.circle")
                    .font(.callout)
            }
            .toggleStyle(.button)
            .help("Mask IP and MAC addresses (for screenshots / screen-sharing)")

            Button {
                monitor.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.callout)
            }
            .buttonStyle(.borderless)

            // Opt-in external-IP reveal — the app's only active outbound query.
            Button {
                showExternalIP.toggle()
                // Re-probe on every open (not just the first) so it can never show a stale
                // exit/underlay verdict after the network changed — e.g. a VPN disconnect.
                if showExternalIP && !monitor.externalRevealing {
                    monitor.revealExternalIP()
                }
            } label: {
                Label("Public IP", systemImage: "globe")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .help("Actively look up your public IP as the internet sees it — the app's only outbound query, on demand")
            .popover(isPresented: $showExternalIP, arrowEdge: .bottom) { externalIPPopover }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
    }

    // MARK: - External IP

    private var externalIPPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Public IP", systemImage: "globe").font(.headline)
            Text("How the internet sees you — an active STUN lookup, the app's only outbound query.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            if monitor.externalRevealing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Looking up…").font(.callout).foregroundColor(.secondary)
                }
            } else {
                externalRow("Exit — default route", monitor.externalExit,
                            "What the world sees — through the VPN tunnel when one is up")
                externalRow("Underlay — carrier", monitor.externalUnderlay,
                            "Your real ISP address, bypassing the VPN")
                if let e = monitor.externalExit, let u = monitor.externalUnderlay {
                    Text(e == u ? "Same address — no active tunnel." : "Addresses differ — traffic is tunneled.")
                        .font(.caption2).foregroundColor(.secondary).padding(.top, 1)
                } else if monitor.externalExit == nil && monitor.externalUnderlay == nil {
                    Text("No response — a STUN server may be blocked on this network.")
                        .font(.caption2).foregroundColor(.secondary).padding(.top, 1)
                }
            }
            Button {
                monitor.revealExternalIP()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise").font(.caption)
            }
            .disabled(monitor.externalRevealing)
            .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 300)
    }

    private func externalRow(_ label: String, _ ip: String?, _ help: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Text(ip.map { Privacy.mask($0, on: privacy) } ?? "—")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .help(help)
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack {
            let upCount   = monitor.interfaces.filter(\.hasLink).count
            let totalCount = monitor.interfaces.count
            let hiddenCount = monitor.interfaces.count - displayedInterfaces.count
            Circle().fill(.green).frame(width: 7, height: 7)
            Text("\(upCount) / \(totalCount) interfaces up")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            if hideUnused && hiddenCount > 0 {
                Text("· \(hiddenCount) inactive hidden")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            // System-level AC/charging (NOT per-port — macOS exposes no per-port
            // power direction, so this lives here rather than on a USB-C port).
            if let power = monitor.systemPower, let label = power.label {
                Text("·").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.4))
                Image(systemName: power.charging ? "bolt.fill" : "powerplug.fill")
                    .font(.system(size: 9))
                    .foregroundColor(power.charging ? .green : .secondary)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .help("System power state from the battery controller. macOS does not reveal which USB-C port delivers or receives power, so this is not tied to a port.")
            }
            Spacer()
            Text("v\(AppInfo.version) · \(AppInfo.releaseChannel)")
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.42))
                .help("NetLights \(AppInfo.versionString) — \(AppInfo.releaseChannel) build")
            Text("·").font(.system(size: 10)).foregroundColor(Color(white: 0.35))
            Text("Auto-refresh every 0.75s")
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.5))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    // MARK: - Routes table

    private var routesTable: some View {
        let b = classifyRoutes(monitor.routes, gateways: monitor.gateways)
        let key: (RouteEntry) -> (UInt32, String) = { routeSortKey($0.destination) }
        let byKey: (RouteEntry, RouteEntry) -> Bool = { key($0) < key($1) }
        let direct = b.direct.sorted(by: byKey)
        let encrypted = b.encrypted.sorted(by: byKey)
        let local = b.local.sorted(by: byKey)
        let flat = monitor.routes.sorted(by: byKey)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(routesSorted
                     ? "Flat · sorted by destination"
                     : "Grouped: Direct · Encrypted · Local")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Toggle(isOn: $routesSorted) {
                    Label("Sort by route", systemImage: "arrow.up.arrow.down")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .help("Switch between grouped sections (split-tunnel Direct, Encrypted VPN, Local) and one flat list sorted numerically by destination")
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            Divider()
            Table(of: RouteEntry.self) {
                TableColumn("Destination") { r in
                    HStack {
                        if r.isDefault {
                            Image(systemName: "star.fill").foregroundColor(.yellow).font(.caption)
                        }
                        Text(Privacy.mask(r.destination, on: privacy)).font(.system(.body, design: .monospaced))
                    }
                }
                .width(min: 130, ideal: 160)

                TableColumn("Gateway") { r in
                    Text(Privacy.mask(r.gateway, on: privacy)).font(.system(.body, design: .monospaced))
                }
                .width(min: 130, ideal: 160)

                TableColumn("Netmask") { r in
                    Text(r.netmask ?? "").font(.system(.body, design: .monospaced))
                }
                .width(min: 120, ideal: 140)

                TableColumn("Interface") { r in
                    Text(r.interfaceName).font(.system(.body, design: .monospaced))
                }
                .width(min: 70, ideal: 90)

                TableColumn("Svc order") { r in
                    // macOS has no numeric route metric; the network service order is
                    // what decides which default wins. Lower = higher priority.
                    if let rank = monitor.serviceRank[r.interfaceName] {
                        Text("\(rank + 1)").font(.system(.body, design: .monospaced))
                            .foregroundColor(r.isDefault ? .primary : .secondary)
                    } else {
                        Text("—").foregroundColor(.secondary)
                    }
                }
                .width(min: 60, ideal: 70)

                TableColumn("Flags") { r in
                    Text(r.flags).font(.system(.body, design: .monospaced)).foregroundColor(.secondary)
                }
                .width(min: 50, ideal: 60)
            } rows: {
                if routesSorted {
                    ForEach(flat) { TableRow($0) }
                } else {
                    if !direct.isEmpty {
                        Section("Direct — split-tunnel (unencrypted)") {
                            ForEach(direct) { TableRow($0) }
                        }
                    }
                    if !encrypted.isEmpty {
                        Section("Encrypted — VPN tunnel") {
                            ForEach(encrypted) { TableRow($0) }
                        }
                    }
                    Section("Local") {
                        ForEach(local) { TableRow($0) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Interfaces table

    /// Whether an interface has current rx/tx traffic (drives the bridge's inactive-hide).
    private func ifaceActive(_ id: String) -> Bool {
        let t = monitor.trafficStates[id]
        return t?.rxActive == true || t?.txActive == true
    }

    private var displayedInterfaces: [InterfaceInfo] {
        hideUnused ? monitor.interfaces.filter { !$0.isHiddenWhenInactive(active: ifaceActive($0.id)) }
                   : monitor.interfaces
    }

    private var interfaceTable: some View {
        Table(displayedInterfaces) {
            TableColumn("Interface") { i in
                HStack {
                    Image(systemName: i.category.systemImage).foregroundColor(.accentColor)
                    Text(i.id).font(.system(.body, design: .monospaced))
                }
            }
            .width(min: 90, ideal: 110)

            TableColumn("Hardware Port") { i in
                Text(i.displayName ?? "—").foregroundColor(i.displayName == nil ? .secondary : .primary)
            }
            .width(min: 120, ideal: 150)

            TableColumn("Description") { i in
                Text(i.subtitleLabel)
                    .foregroundColor(i.primaryIP != nil ? .primary : .secondary)
            }
            .width(min: 100, ideal: 130)

            TableColumn("Type") { i in Text(i.category.rawValue) }
                .width(min: 80, ideal: 100)

            TableColumn("IPv4") { i in
                Text(Privacy.mask(i.ipv4Addresses.joined(separator: ", "), on: privacy))
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 120, ideal: 150)

            TableColumn("MAC") { i in
                Text(Privacy.mask(i.macAddress ?? "—", on: privacy)).font(.system(.body, design: .monospaced))
            }
            .width(min: 130, ideal: 140)

            TableColumn("Speed") { i in Text(i.formattedSpeed ?? "—") }
                .width(min: 70, ideal: 80)

            TableColumn("Link") { i in
                switch i.linkState {
                case .up:      Label("Up",      systemImage: "circle.fill").foregroundColor(.green)
                case .down:    Label("Down",    systemImage: "circle.fill").foregroundColor(.red)
                case .unknown: Label("Unknown", systemImage: "circle.fill").foregroundColor(.gray)
                }
            }
            .width(min: 70, ideal: 80)

            TableColumn("RX") { i in
                Text(formatBytes(i.rxBytes)).font(.system(.body, design: .monospaced))
            }
            .width(min: 90)

            TableColumn("TX") { i in
                Text(formatBytes(i.txBytes)).font(.system(.body, design: .monospaced))
            }
            .width(min: 90)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Devices table

    /// Connected peripherals (USB tree + external displays) flattened in tree
    /// pre-order: each port's root devices in order, and every hub immediately
    /// followed by its descendants — so a child always sits directly beneath its
    /// parent. `depth` drives the row indentation. (A plain (port, name) sort would
    /// scatter a hub's children among unrelated devices.)
    private var deviceTree: (rows: [AttachedDevice], depth: [String: Int]) {
        let devs = monitor.attachedDevices
        let byId = Dictionary(devs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var childrenOf: [String: [AttachedDevice]] = [:]
        var roots: [AttachedDevice] = []
        for d in devs {
            if let pid = d.parentID, byId[pid] != nil { childrenOf[pid, default: []].append(d) }
            else { roots.append(d) }
        }
        func less(_ a: AttachedDevice, _ b: AttachedDevice) -> Bool {
            a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        var rows: [AttachedDevice] = []
        var depth: [String: Int] = [:]
        func visit(_ d: AttachedDevice, _ level: Int) {
            rows.append(d); depth[d.id] = level
            for c in (childrenOf[d.id] ?? []).sorted(by: less) { visit(c, min(level + 1, 8)) }
        }
        let sortedRoots = roots.sorted {
            $0.receptacle != $1.receptacle ? $0.receptacle < $1.receptacle : less($0, $1)
        }
        for r in sortedRoots { visit(r, 0) }
        return (rows, depth)
    }


    private var devicesTable: some View {
        let tree = deviceTree
        return Group {
            if tree.rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "cable.connector.slash")
                        .font(.system(size: 32, weight: .light))
                        .foregroundColor(.secondary)
                    Text("No external devices detected")
                        .foregroundColor(.secondary)
                    Text("USB peripherals, hubs/docks, and external displays appear here when connected.")
                        .font(.caption).foregroundColor(.secondary.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(tree.rows) {
                    TableColumn("Device") { d in
                        HStack {
                            Image(systemName: d.systemImage).foregroundColor(.cyan)
                            // Indent by tree depth so a hub's peripherals read beneath it.
                            Text(d.name).padding(.leading, CGFloat(tree.depth[d.id] ?? 0) * 16)
                        }
                    }
                    .width(min: 150, ideal: 200)

                    TableColumn("Type") { d in Text(d.kind.label) }
                        .width(min: 70, ideal: 90)

                    TableColumn("Manufacturer") { d in
                        Text(d.vendorName ?? "—").foregroundColor(d.vendorName == nil ? .secondary : .primary)
                    }
                    .width(min: 100, ideal: 130)

                    TableColumn("Bus") { d in Text(d.connectionLabel) }
                        .width(min: 70, ideal: 90)

                    TableColumn("Speed / Mode") { d in
                        Text(d.speedLabel)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(d.speedLabel == "—" ? .secondary : .primary)
                    }
                    .width(min: 120, ideal: 160)

                    TableColumn("Class") { d in
                        Text(d.classLabel).foregroundColor(.secondary)
                    }
                    .width(min: 90, ideal: 110)

                    TableColumn("VID:PID") { d in
                        Text(d.idLabel).font(.system(.body, design: .monospaced)).foregroundColor(.secondary)
                    }
                    .width(min: 90, ideal: 110)

                    // Shared with the TUI and the web UI (InterfaceModel.swift) so all three
                    // name a receptacle identically.
                    TableColumn("Port") { d in Text(devicePortLabel(d, monitor.hardwarePorts)) }
                        .width(min: 80, ideal: 110)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - DNS resolvers

    /// Search / scoped domains can name an employer or internal network, so privacy
    /// mode redacts them (Privacy.mask only covers IP/MAC). "—" when there are none.
    private func maskDomains(_ list: [String]) -> String {
        guard !list.isEmpty else { return "—" }
        if privacy { return "••• (\(list.count) hidden)" }
        return list.joined(separator: ", ")
    }

    /// The scope label — but a user-defined service name (e.g. "Acme-Corp-VPN") can
    /// name an employer/person, so privacy mode swaps it for the bound interface or a
    /// generic label. Interface names (en0 / utun3) are non-identifying and stay.
    private func scopeText(_ c: DNSConfig) -> String {
        if privacy && c.userNamedScope { return c.interfaceName ?? "Service" }
        return c.scopeLabel
    }

    /// The DNS tab: a banner answering "which resolvers win" (the active/global set)
    /// above a table of every service's set — so a VPN pushing its own (or a split-DNS)
    /// resolver is visible, and you can see whether it's the one actually in effect.
    private var dnsView: some View {
        let sets = monitor.dnsConfigs
        let global = sets.first { $0.isGlobal }
        let services = sets.filter { !$0.isGlobal }
        return VStack(spacing: 0) {
            dnsBanner(global)
            Divider()
            if services.isEmpty {
                emptyDNS
            } else {
                dnsTable(services)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "Active resolvers" summary — the effective set the system resolves against.
    private func dnsBanner(_ g: DNSConfig?) -> some View {
        let hasServers = g.map { !$0.servers.isEmpty } ?? false
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: hasServers ? "checkmark.seal.fill" : "questionmark.circle")
                .foregroundColor(hasServers ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text("Active resolvers")
                    .font(.caption).foregroundColor(.secondary)
                if let g, hasServers {
                    Text(Privacy.mask(g.servers.joined(separator: "   "), on: privacy))
                        .font(.system(.body, design: .monospaced))
                    HStack(spacing: 12) {
                        if let iface = g.interfaceName {
                            Label(iface, systemImage: "arrow.up.forward")
                                .font(.caption).foregroundColor(.secondary)
                                .help("The primary interface the active resolvers ride")
                        }
                        if !g.searchDomains.isEmpty {
                            Text("search: \(maskDomains(g.searchDomains))")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                } else {
                    Text("None reported").foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyDNS: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(.secondary)
            Text("No DNS resolver sets reported")
                .foregroundColor(.secondary)
            Text("Unusual — the system normally has at least one active resolver.")
                .font(.caption).foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dnsTable(_ rows: [DNSConfig]) -> some View {
        Table(rows) {
            TableColumn("Service / Scope") { c in
                HStack(spacing: 6) {
                    if c.isPrimary {
                        Image(systemName: "star.fill").foregroundColor(.yellow).font(.caption)
                            .help("Primary service — its resolvers answer unscoped queries")
                    }
                    Text(scopeText(c))
                    if c.isSupplemental {
                        Text("split-DNS")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.22)))
                            .help("Handles only specific domains — see \"Scoped to\"")
                    }
                }
            }
            .width(min: 150, ideal: 200)

            TableColumn("Interface") { c in
                Text(c.interfaceName ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(c.interfaceName == nil ? .secondary : .primary)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Resolvers") { c in
                Text(c.servers.isEmpty ? "—" : Privacy.mask(c.servers.joined(separator: ", "), on: privacy))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(c.servers.isEmpty ? .secondary : .primary)
            }
            .width(min: 160, ideal: 220)

            TableColumn("Search Domains") { c in
                Text(maskDomains(c.searchDomains))
                    .foregroundColor(c.searchDomains.isEmpty ? .secondary : .primary)
            }
            .width(min: 110, ideal: 150)

            TableColumn("Scoped to") { c in
                Text(maskDomains(c.matchDomains))
                    .foregroundColor(c.matchDomains.isEmpty ? .secondary : .primary)
                    .help(c.matchDomains.isEmpty ? "" : "Split-DNS: this set answers only these domains")
            }
            .width(min: 110, ideal: 150)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formatBytes(_ n: UInt64) -> String {
        switch n {
        case ..<1024:           return "\(n) B"
        case ..<1_048_576:      return String(format: "%.1f KB", Double(n) / 1024)
        case ..<1_073_741_824:  return String(format: "%.1f MB", Double(n) / 1_048_576)
        default:                return String(format: "%.2f GB", Double(n) / 1_073_741_824)
        }
    }
}

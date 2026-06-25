import SwiftUI

struct ContentView: View {
    @ObservedObject var monitor: NetworkMonitor
    @State private var selectedTab: Tab = .graph
    @State private var hideUnused: Bool = false
    @State private var privacy: Bool = false

    enum Tab: String, CaseIterable {
        case graph      = "Graph"
        case routes     = "Routes"
        case interfaces = "Interfaces"
        case devices    = "Devices"
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
            .frame(width: 360)

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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack {
            let upCount   = monitor.interfaces.filter(\.hasLink).count
            let totalCount = monitor.interfaces.count
            let unusedCount = monitor.interfaces.filter(\.isUnused).count
            Circle().fill(.green).frame(width: 7, height: 7)
            Text("\(upCount) / \(totalCount) interfaces up")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            if hideUnused && unusedCount > 0 {
                Text("· \(unusedCount) inactive hidden")
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
        Table(monitor.routes) {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Interfaces table

    private var displayedInterfaces: [InterfaceInfo] {
        hideUnused ? monitor.interfaces.filter { !$0.isUnused } : monitor.interfaces
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

    /// "Left · Front" location label for a device's receptacle (— for displays / unknown).
    private func devicePortLabel(_ d: AttachedDevice) -> String {
        if d.receptacle == -2 { return "Video out" }
        guard let p = monitor.hardwarePorts.first(where: { $0.id == d.receptacle }), !p.side.isEmpty else {
            return d.receptacle >= 0 ? "Port \(d.receptacle)" : "—"
        }
        return p.position.isEmpty ? p.side : "\(p.side) · \(p.position)"
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

                    TableColumn("Port") { d in Text(devicePortLabel(d)) }
                        .width(min: 80, ideal: 110)
                }
            }
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

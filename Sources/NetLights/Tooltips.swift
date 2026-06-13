import SwiftUI

// Standalone tooltip views, rendered centrally by NetworkGraphView (a single
// pointer-tracked tooltip), so hover is immune to per-node tracking-area churn.

struct HardwarePortTooltip: View {
    let port: HardwarePort

    private var titleLabel: String { port.isPhone ? port.deviceName : "TB Port \(port.id)" }
    private var location: String {
        guard !port.side.isEmpty else { return "" }
        return port.position.isEmpty ? port.side : "\(port.side) · \(port.position)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titleLabel).font(.system(.headline, design: .monospaced))
            Divider()
            if port.isPhone {
                row("Type", "USB-C \(port.deviceName)")
                row("Channels", "\(port.childBSDNames.count) virtual interfaces")
                row("en* names", port.childBSDNames.joined(separator: ", "))
                row("Status", port.hasConnectedDevice ? "Connected" : "Disconnected")
            } else {
                if !location.isEmpty { row("Location", location) }
                row("Status", port.hasConnectedDevice ? "Device connected" : "No device")
                if port.hasPower { row("Power", "USB-C charger (plug)") }
                row("Interfaces", port.childBSDNames.joined(separator: ", "))
            }
        }
        .frame(width: 210, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial)
            .shadow(color: .black.opacity(0.3), radius: 8))
    }

    @ViewBuilder private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label + ": ").font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary).frame(width: 84, alignment: .leading)
            Text(value).font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DeviceTooltip: View {
    let device: AttachedDevice
    let portLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(device.name).font(.system(.headline, design: .monospaced))
            Divider()
            row("Class", device.kind.label)
            if let loc = portLabel { row("Port", loc) }
            if let bsd = device.interfaceBSD { row("Interface", bsd) }
        }
        .frame(width: 210, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial)
            .shadow(color: .black.opacity(0.3), radius: 8))
    }

    @ViewBuilder private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label + ": ").font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary).frame(width: 72, alignment: .leading)
            Text(value).font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct GatewayTooltip: View {
    let gateway: GatewayNode
    let routes: [RouteEntry]
    @Environment(\.privacyMode) private var privacyMode

    /// For a VPN gateway, the physical default gateway it egresses through.
    private var egressGateway: String? {
        guard gateway.isVPN else { return nil }
        return routes.first {
            $0.isDefault && $0.gateway != gateway.id && $0.gateway.contains(".")
            && !$0.interfaceName.hasPrefix("utun") && !$0.interfaceName.hasPrefix("ipsec")
        }?.gateway
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Privacy.mask(gateway.id, on: privacyMode))
                .font(.system(.headline, design: .monospaced))
            Divider()
            row("Role", gateway.roleLabel)
            let vias = gateway.reachableVia
            row(vias.count > 1 ? "Via (priority)" : "Via",
                vias.enumerated().map { vias.count > 1 ? "\($0.offset + 1). \($0.element)" : $0.element }
                    .joined(separator: "  "))
            if let eg = egressGateway { row("Egress", "via \(eg)") }

            let myRoutes = routes.filter { $0.gateway == gateway.id }
            if !myRoutes.isEmpty {
                row("Routes", "\(myRoutes.count) entries")
                ForEach(myRoutes.prefix(5)) { r in
                    row("  →", "\(r.destination)\(r.netmask.map { "/\($0)" } ?? "")")
                }
                if myRoutes.count > 5 {
                    Text("  … and \(myRoutes.count - 5) more")
                        .font(.system(size: 8)).foregroundColor(.secondary)
                }
            }
        }
        .frame(width: 240, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial)
            .shadow(color: .black.opacity(0.3), radius: 8))
    }

    @ViewBuilder private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label + ": ").font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary).frame(width: 60, alignment: .leading)
            Text(Privacy.mask(value, on: privacyMode))
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

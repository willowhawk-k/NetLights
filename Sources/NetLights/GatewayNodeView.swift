import SwiftUI

struct GatewayNodeView: View {
    let gateway: GatewayNode
    let routes: [RouteEntry]

    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 5) {
                Image(systemName: gateway.systemImage)
                    .font(.system(size: 22, weight: .light))
                    .foregroundColor(accentColor)

                Text(gateway.id)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)

                Text(gateway.roleLabel)
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(width: 100, height: 76)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(borderColor, lineWidth: isHovered ? 1.5 : 1)
                    )
            )
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isHovered)

            // Live LED — default gateways always lit; others dim
            Circle()
                .fill(gateway.isDefault ? Color.green : Color(white: 0.45))
                .frame(width: 8, height: 8)
                .shadow(color: gateway.isDefault ? .green.opacity(0.5) : .clear, radius: 3)
                .offset(x: -5, y: 5)
                .accessibilityHidden(true)
        }
        .onHover { isHovered = $0 }
        .overlay(alignment: .top) {
            if isHovered {
                gatewayTooltip
                    .offset(y: -140)
                    .zIndex(100)
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.1), value: isHovered)
            }
        }
    }

    private var gatewayTooltip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(gateway.id)
                .font(.system(.headline, design: .monospaced))

            Divider()

            row("Role",  gateway.roleLabel)
            row("Via",   gateway.reachableVia.joined(separator: ", "))
            if let eg = egressGateway {
                row("Egress", "via \(eg)")
            }

            let myRoutes = routes.filter { $0.gateway == gateway.id }
            if !myRoutes.isEmpty {
                row("Routes", "\(myRoutes.count) entries")
                ForEach(myRoutes.prefix(5)) { r in
                    row("  →", "\(r.destination)\(r.netmask.map { "/\($0)" } ?? "")")
                }
                if myRoutes.count > 5 {
                    Text("  … and \(myRoutes.count - 5) more")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.3), radius: 8)
        )
        .frame(minWidth: 220, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label + ": ")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    /// Icon tint: VPN gateways blue, physical default orange, others grey.
    private var accentColor: Color {
        if gateway.isVPN { return .blue }
        return gateway.isDefault ? .orange : .secondary
    }

    /// For a VPN gateway, the physical default gateway it ultimately egresses
    /// through (the *other* default route, not over a tunnel).
    private var egressGateway: String? {
        guard gateway.isVPN else { return nil }
        return routes.first {
            $0.isDefault && $0.gateway != gateway.id
            && $0.gateway.contains(".")
            && !$0.interfaceName.hasPrefix("utun")
            && !$0.interfaceName.hasPrefix("ipsec")
        }?.gateway
    }

    private var cardBackground: Color {
        isHovered
            ? Color(nsColor: .controlBackgroundColor).opacity(0.95)
            : Color(nsColor: .controlBackgroundColor).opacity(0.55)
    }

    private var borderColor: Color {
        if isHovered         { return .accentColor.opacity(0.6) }
        if gateway.isVPN     { return .blue.opacity(0.5) }
        if gateway.isDefault { return .orange.opacity(0.5) }
        return Color(white: 0.4).opacity(0.3)
    }
}

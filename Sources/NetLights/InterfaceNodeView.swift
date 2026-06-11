import SwiftUI

// MARK: - Tooltip content

struct InterfaceTooltip: View {
    let iface: InterfaceInfo
    let routes: [RouteEntry]

    var defaultRoute: RouteEntry? {
        routes.first { $0.isDefault && $0.interfaceName == iface.id }
    }

    var ifaceRoutes: [RouteEntry] {
        routes.filter { $0.interfaceName == iface.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(iface.id)
                .font(.system(.headline, design: .monospaced))
                .foregroundColor(.primary)

            Divider()

            if let display = iface.displayName {
                row("Port", display)
            }
            row("Type", iface.category.rawValue)
            row("Layer", iface.category.layerLabel)

            if iface.isIPhoneHotspot {
                row("Device", "iPhone (USB Hotspot)")
            }
            if let mac = iface.macAddress {
                row("MAC", mac)
            }

            if !iface.ipv4Addresses.isEmpty {
                row("IPv4", iface.ipv4Addresses.joined(separator: ", "))
            }

            if !iface.ipv6Addresses.filter({ !$0.hasPrefix("fe80") }).isEmpty {
                let addrs = iface.ipv6Addresses.filter { !$0.hasPrefix("fe80") }
                row("IPv6", addrs.joined(separator: "\n      "))
            }

            if let speed = iface.formattedSpeed {
                row("Speed", speed)
            }

            row("MTU", "\(iface.mtu)")
            row("Link", linkLabel)

            if let dr = defaultRoute {
                row("Default GW", dr.gateway)
            }

            if !ifaceRoutes.isEmpty {
                row("Routes", "\(ifaceRoutes.count)")
            }

            row("RX", formatBytes(iface.rxBytes))
            row("TX", formatBytes(iface.txBytes))
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.3), radius: 8)
        )
        .frame(minWidth: 240, alignment: .leading)
    }

    private var linkLabel: String {
        switch iface.linkState {
        case .up:      return "Up"
        case .down:    return "Down"
        case .unknown: return iface.isRunning ? "Running" : "Unknown"
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label + ": ")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)
        }
    }

    private func formatBytes(_ n: UInt64) -> String {
        switch n {
        case ..<1024:               return "\(n) B"
        case ..<1_048_576:          return String(format: "%.1f KB", Double(n) / 1024)
        case ..<1_073_741_824:      return String(format: "%.1f MB", Double(n) / 1_048_576)
        default:                    return String(format: "%.2f GB", Double(n) / 1_073_741_824)
        }
    }
}

// MARK: - Interface node card

struct InterfaceNodeView: View {
    let iface: InterfaceInfo
    let traffic: TrafficState?
    let routes: [RouteEntry]

    @State private var isHovered = false

    private var ledState: LEDView.LEDState {
        let hasTraffic = traffic?.rxActive == true || traffic?.txActive == true
        return LEDView.LEDState(hasLink: iface.hasLink, hasTraffic: hasTraffic)
    }

    private var dimmed: Bool { !iface.hasLink }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 6) {
                // Icon
                Image(systemName: iface.effectiveSystemImage)
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(iface.isIPhoneHotspot ? .green : (dimmed ? Color(white: 0.45) : .primary))
                    .frame(width: 44, height: 44)

                // Interface name
                Text(iface.id)
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .foregroundColor(dimmed ? .secondary : .primary)

                Text(iface.subtitleLabel)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(width: 100, height: 90)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(borderColor, lineWidth: isHovered ? 1.5 : 1)
                    )
            )
            .opacity(dimmed ? 0.55 : 1.0)
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isHovered)

            // LED in top-right
            LEDView(state: ledState)
                .offset(x: -6, y: 6)
        }
        .onHover { isHovered = $0 }
        .overlay(alignment: .top) {
            if isHovered {
                InterfaceTooltip(iface: iface, routes: routes)
                    .offset(y: -160)
                    .zIndex(100)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
                    .animation(.easeOut(duration: 0.1), value: isHovered)
            }
        }
    }

    private var cardBackground: Color {
        if isHovered {
            return Color(nsColor: .controlBackgroundColor).opacity(0.95)
        }
        return Color(nsColor: .controlBackgroundColor).opacity(0.7)
    }

    private var borderColor: Color {
        if isHovered { return .accentColor.opacity(0.7) }
        if dimmed { return Color(white: 0.3).opacity(0.5) }
        return Color(white: 0.5).opacity(0.4)
    }
}

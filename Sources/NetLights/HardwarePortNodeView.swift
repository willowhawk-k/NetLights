import SwiftUI

/// Represents a physical USB-C / Thunderbolt port slot at the L0 "Hardware" band,
/// or a virtual iPhone/iPad USB-connected device node (port.isPhone == true).
struct HardwarePortNodeView: View {
    let port: HardwarePort
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 4) {
                Image(systemName: iconName)
                    .font(.system(size: 18, weight: .light))
                    .foregroundColor(iconColor)

                Text(titleLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.75))

                if !subtitleLabel.isEmpty {
                    Text(subtitleLabel)
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(width: 84, height: 62)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(borderColor, lineWidth: 1)
                    )
            )
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isHovered)

            // Status dot
            Circle()
                .fill(port.hasConnectedDevice ? Color.green : Color(white: 0.35))
                .frame(width: 7, height: 7)
                .shadow(color: port.hasConnectedDevice ? .green.opacity(0.5) : .clear, radius: 3)
                .offset(x: -4, y: 4)
        }
        .overlay(alignment: .topLeading) {
            // Power-delivery badge for ports with a charger attached.
            if port.hasPower {
                Image(systemName: "powerplug.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.yellow)
                    .padding(2)
                    .background(Circle().fill(Color.black.opacity(0.4)))
                    .offset(x: -3, y: -3)
                    .help("USB-C power connected")
            }
        }
        .onHover { isHovered = $0 }
        .overlay(alignment: .top) {
            if isHovered {
                tooltip
                    .offset(y: -110)
                    .zIndex(100)
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.1), value: isHovered)
            }
        }
    }

    // MARK: - Labels

    private var iconName: String {
        port.isPhone ? "iphone" : "bolt.fill"
    }

    private var iconColor: Color {
        if port.hasConnectedDevice {
            return port.isPhone ? .green : .orange
        }
        return Color(white: 0.4)
    }

    private var titleLabel: String {
        port.isPhone ? "iPhone" : "TB Port \(port.id)"
    }

    private var subtitleLabel: String {
        if port.isPhone { return "USB-C" }
        guard !port.side.isEmpty else { return "" }
        return port.position.isEmpty ? port.side : "\(port.side) · \(port.position)"
    }

    // MARK: - Tooltip

    private var tooltip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titleLabel)
                .font(.system(.headline, design: .monospaced))
            Divider()
            if port.isPhone {
                row("Type", "USB-C iPhone / iPad")
                row("Channels", "\(port.childBSDNames.count) virtual interfaces")
                row("en* names", port.childBSDNames.joined(separator: ", "))
                row("Status", port.hasConnectedDevice ? "Connected" : "Disconnected")
            } else {
                if !port.side.isEmpty {
                    row("Location", subtitleLabel)
                }
                row("Status", port.hasConnectedDevice ? "Device connected" : "No device")
                if port.hasPower { row("Power", "USB-C charger ⚡︎") }
                row("Virtual en*", port.childBSDNames.joined(separator: ", "))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.3), radius: 8)
        )
        .frame(minWidth: 200, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label + ": ")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
        }
    }

    private var cardBackground: Color {
        isHovered
            ? Color(nsColor: .controlBackgroundColor).opacity(0.95)
            : Color(nsColor: .controlBackgroundColor).opacity(0.45)
    }

    private var borderColor: Color {
        if isHovered { return port.isPhone ? .green.opacity(0.6) : .orange.opacity(0.6) }
        if port.hasConnectedDevice {
            return port.isPhone ? .green.opacity(0.35) : .orange.opacity(0.35)
        }
        return Color(white: 0.4).opacity(0.25)
    }
}

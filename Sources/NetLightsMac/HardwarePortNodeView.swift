import SwiftUI

/// Represents a physical USB-C / Thunderbolt port slot at the L0 "Hardware" band,
/// or a virtual iPhone/iPad USB-connected device node (port.isPhone == true).
struct HardwarePortNodeView: View {
    let port: HardwarePort
    var isHovered: Bool = false

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
    }

    // MARK: - Labels

    private var iconName: String {
        port.isPhone ? (port.deviceName == "iPad" ? "ipad" : "iphone") : "bolt.fill"
    }

    private var iconColor: Color {
        if port.hasConnectedDevice {
            return port.isPhone ? .green : .orange
        }
        return Color(white: 0.4)
    }

    private var titleLabel: String {
        port.isPhone ? port.deviceName : "TB Port \(port.id)"
    }

    private var subtitleLabel: String {
        if port.isPhone { return port.connectionMedium }
        guard !port.side.isEmpty else { return "" }
        return port.position.isEmpty ? port.side : "\(port.side) · \(port.position)"
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

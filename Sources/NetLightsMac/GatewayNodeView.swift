import SwiftUI

struct GatewayNodeView: View {
    let gateway: GatewayNode
    var isHovered: Bool = false

    @Environment(\.privacyMode) private var privacyMode

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 5) {
                Image(systemName: gateway.systemImage)
                    .font(.system(size: 20, weight: .light))
                    .foregroundColor(accentColor)

                Text(gateway.titleLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.85))

                Text(Privacy.mask(gateway.id, on: privacyMode))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.secondary)

                if let n = gateway.networkName {
                    Text(privacyMode ? "••••" : n)
                        .font(.system(size: 8))
                        .foregroundColor(.teal)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(width: 100, height: gateway.networkName == nil ? 76 : 90)
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
    }

    /// Icon tint: VPN gateways blue, physical default orange, others grey.
    private var accentColor: Color {
        if gateway.isVPN { return .blue }
        return gateway.isDefault ? .orange : .secondary
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

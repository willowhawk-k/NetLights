import SwiftUI

/// The Mac's battery as a Hardware-row entity: charge level + state (charging /
/// powered / on battery) + adapter info on hover. All from AppleSmartBattery —
/// a SYSTEM fact, deliberately not tied to any USB-C port (macOS exposes no
/// per-port power direction).
struct BatteryEntityView: View {
    let power: SystemPower

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .light))
                .foregroundColor(color)
            Text(power.level.map { "\($0)%" } ?? "Battery")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.primary.opacity(0.8))
            Text(power.stateLabel)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(width: 84, height: 62)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(color.opacity(0.35), lineWidth: 1))
        )
        .help(helpText)
    }

    /// Battery glyph by charge level (the SF Symbol shows a proportional fill).
    private var symbol: String {
        switch power.level ?? 100 {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default:    return "battery.100"
        }
    }

    private var color: Color {
        if power.charging { return .green }
        if !power.onAC, (power.level ?? 100) <= 20 { return .orange }
        return power.onAC ? .green : .secondary
    }

    private var helpText: String {
        var parts = [power.stateLabel]
        if let a = power.adapterLabel { parts.append("via \(a)") }
        // Honesty: macOS doesn't reveal which port (or MagSafe vs USB-C) supplies power.
        if power.onAC { parts.append("— port not exposed by macOS") }
        return parts.joined(separator: " ")
    }
}

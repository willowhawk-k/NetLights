import SwiftUI

/// Represents the Wi-Fi network/router the Mac is associated with — a logical
/// "out there in range" entity shown in the Hardware row (Wi-Fi has no physical
/// port, but there's a real AP on the other end of the radio link).
struct WifiEntityView: View {
    let ssid: String?
    @Environment(\.privacyMode) private var privacyMode

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: "wifi")
                .font(.system(size: 18, weight: .light))
                .foregroundColor(.blue)
            Text("Wi-Fi")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.primary.opacity(0.75))
            Text(label)
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
                    .stroke(Color.blue.opacity(0.35), lineWidth: 1))
        )
    }

    private var label: String {
        guard let s = ssid else { return "network" }
        return privacyMode ? "••••" : s
    }
}

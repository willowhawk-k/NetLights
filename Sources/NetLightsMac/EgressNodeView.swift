import SwiftUI

/// The "out to the internet" node — the uplink beyond the default gateway,
/// labelled with the network's identity (Wi-Fi SSID, wired domain, …) when known.
struct EgressNodeView: View {
    let egress: EgressInfo
    @Environment(\.privacyMode) private var privacyMode

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "globe")
                    .font(.system(size: 22, weight: .light))
                    .foregroundColor(.teal)
                // Small badge showing the uplink type.
                Image(systemName: egress.kind.systemImage)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.teal)
                    .padding(2)
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                    .offset(x: 5, y: 3)
            }

            Text("Internet")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.primary.opacity(0.8))

            Text(label)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(width: 100, height: 70)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.teal.opacity(0.4), lineWidth: 1))
        )
    }

    /// SSIDs and domains can identify a location, so mask them in Privacy mode.
    private var label: String {
        guard let name = egress.name else { return egress.kind.label }
        return privacyMode ? "\(egress.kind.label) ••••" : name
    }
}

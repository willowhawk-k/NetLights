import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            AppIconView()
                .frame(width: 104, height: 104)
                .shadow(color: .black.opacity(0.4), radius: 8, y: 3)

            VStack(spacing: 4) {
                Text(AppInfo.name)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(AppInfo.tagline)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Text(AppInfo.versionString)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }

            Divider().frame(width: 240)

            VStack(spacing: 6) {
                creditRow("Created by", AppInfo.author)
                creditRow("Engineering partner", "Claude — Anthropic")
                creditRow("Copyright", AppInfo.copyright)
            }

            Text("Built with SwiftUI on macOS. Reads live interface, routing, and port-topology data directly from the system — no elevated privileges.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            Text("🤖 Designed and coded in pairing sessions with Claude (Anthropic).")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func creditRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 150, alignment: .trailing)
            Text(value)
                .font(.caption.weight(.medium))
                .frame(width: 170, alignment: .leading)
        }
    }
}

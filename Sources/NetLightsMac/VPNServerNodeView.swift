import SwiftUI

/// The far-side VPN concentrator — the server the encrypted tunnel terminates at,
/// painted BEYOND the Internet node. Styled in VPN blue so it reads as the endpoint
/// of the encrypted pipe. The address masks under Privacy mode.
struct VPNServerNodeView: View {
    let serverIP: String
    var isHovered: Bool = false
    @Environment(\.privacyMode) private var privacyMode

    private let accent = Color.blue

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(accent)

            Text("VPN Server")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.primary.opacity(0.8))

            Text(Privacy.mask(serverIP, on: privacyMode))
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(width: 100, height: 76)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(accent.opacity(isHovered ? 0.9 : 0.45), lineWidth: isHovered ? 1.5 : 1))
        )
        .scaleEffect(isHovered ? 1.04 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

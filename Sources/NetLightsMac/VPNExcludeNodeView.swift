import SwiftUI

/// The split-tunnel "Direct" node — public destinations that bypass the VPN tunnel
/// and egress unencrypted over the physical carrier. Painted in amber beside the
/// encrypted concentrator so the split-tunnel contrast (blue pipe vs plain amber) is
/// unmistakable.
struct VPNExcludeNodeView: View {
    let count: Int
    var isHovered: Bool = false

    private let accent = Color(red: 0.95, green: 0.65, blue: 0.15)

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: "lock.open.fill")
                .font(.system(size: 20, weight: .regular))
                .foregroundColor(accent)

            Text("Direct")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.primary.opacity(0.8))

            Text("\(count) excluded")
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

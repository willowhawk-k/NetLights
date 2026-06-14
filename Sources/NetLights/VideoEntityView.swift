import SwiftUI

/// Represents external displays as a Hardware-row entity. macOS doesn't expose
/// which physical port a monitor is on (DisplayPort-alt-mode displays never show
/// in the Thunderbolt tree, and SPDisplays reports no connection type), so the
/// connected monitors are grouped here rather than pinned to a guessed port.
struct VideoEntityView: View {
    let count: Int

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: "display.2")
                .font(.system(size: 18, weight: .light))
                .foregroundColor(.cyan)
            Text("Displays")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.primary.opacity(0.75))
            Text(count == 1 ? "1 external" : "\(count) external")
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
                    .stroke(Color.cyan.opacity(0.35), lineWidth: 1))
        )
    }
}

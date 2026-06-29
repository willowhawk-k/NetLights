import SwiftUI

/// Connected Bluetooth devices as a Hardware-row entity ("Bluetooth is a kind of
/// network"). Like the Displays entity, the connected devices are grouped under it
/// rather than pinned to a port — Bluetooth has no physical receptacle. Populated
/// only when the user grants the Bluetooth permission (otherwise the app shows no
/// Bluetooth entity at all).
struct BluetoothEntityView: View {
    let count: Int

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: "wave.3.right")
                .font(.system(size: 18, weight: .light))
                .foregroundColor(.blue)
            Text("Bluetooth")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.primary.opacity(0.75))
            Text(count == 1 ? "1 connected" : "\(count) connected")
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
}

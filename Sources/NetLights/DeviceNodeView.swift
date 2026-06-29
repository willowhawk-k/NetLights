import SwiftUI

/// A compact chip for a non-network USB peripheral (audio, storage, hub, …),
/// drawn beside the hardware port it's attached to.
struct DeviceNodeView: View {
    let device: AttachedDevice

    /// Bluetooth chips are tinted blue to match the Bluetooth entity; everything
    /// else (USB peripherals, displays) stays cyan.
    private var tint: Color { device.connection == "Bluetooth" ? .blue : .cyan }

    /// Kind label, with battery % appended when the device reports it (BT HID).
    private var subtitle: String {
        device.batteryLabel.map { "\(device.kind.label) · \($0)" } ?? device.kind.label
    }

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: device.systemImage)
                .font(.system(size: 15, weight: .light))
                .foregroundColor(tint)
            Text(shortName)
                .font(.system(size: 8, weight: .medium))
                .lineLimit(1)
                .foregroundColor(.primary.opacity(0.8))
            Text(subtitle)
                .font(.system(size: 7))
                .lineLimit(1)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
        .frame(width: 74, height: 52)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(tint.opacity(0.35), lineWidth: 1))
        )
    }

    private var shortName: String {
        device.name.count > 12 ? String(device.name.prefix(11)) + "…" : device.name
    }
}

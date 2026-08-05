import SwiftUI
import Foundation

// MARK: - Privacy mode environment

private struct PrivacyModeKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// When true, views mask IP / MAC addresses for screenshots & screen-sharing.
    var privacyMode: Bool {
        get { self[PrivacyModeKey.self] }
        set { self[PrivacyModeKey.self] = newValue }
    }
}

// MARK: - Masking

/// Redacts identifying network addresses inside an arbitrary display string,
/// so the same helper works for node subtitles, gateway labels, and tooltips.
/// Non-sensitive values (loopback, broadcast/netmasks, 0.0.0.0) are left intact.
///
/// The implementation lives in NetLightsCore (`PrivacyMask.swift`) so the TUI and the web
/// UI mask identically — this used to be one of two divergent copies. Kept as a forwarder
/// rather than removed: it's the spelling ~18 SwiftUI call sites already use.
enum Privacy {
    static func mask(_ s: String, on: Bool) -> String { maskAddresses(s, on) }
}

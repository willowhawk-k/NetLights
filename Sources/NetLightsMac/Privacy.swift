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
enum Privacy {
    static func mask(_ s: String, on: Bool) -> String {
        guard on, !s.isEmpty else { return s }
        // Order matters: MAC first (its "xx" placeholders aren't hex, so the IPv6
        // pass won't re-match it), then IPv6, then IPv4.
        var out = s
        out = replace(out, pattern: #"\b[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5}\b"#) { full in
            let parts = full.split(separator: ":")
            return parts.prefix(3).joined(separator: ":") + ":xx:xx:xx"   // keep OUI
        }
        out = replace(out, pattern: #"\b([0-9a-fA-F]{1,4}):[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{0,4}){2,}\b"#) { full in
            let head = full.prefix { $0 != ":" }
            return "\(head):••"                                            // keep first hextet
        }
        out = replace(out, pattern: #"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#) { full in
            // Leave loopback, broadcast/netmasks, and the unspecified address alone.
            if full.hasPrefix("127.") || full.hasPrefix("255.") || full.hasPrefix("0.") {
                return full
            }
            let firstOctet = full.split(separator: ".").first.map(String.init) ?? "x"
            return "\(firstOctet).x.x.x"
        }
        return out
    }

    /// Applies `transform` to every regex match (processed back-to-front so ranges stay valid).
    private static func replace(_ s: String, pattern: String, _ transform: (String) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var result = s
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            let full = ns.substring(with: m.range)
            let replacement = transform(full)
            result = (result as NSString).replacingCharacters(in: m.range, with: replacement)
        }
        return result
    }
}

import Foundation

// The single privacy-masking implementation, shared by the SwiftUI app, the TUI and the
// web UI. It used to exist twice — an NSRegularExpression version in NetLightsMac and a
// hand-rolled one in TUIRender — and the two had drifted: the TUI copy had no IPv6 branch
// at all, and it masked netmasks (turning 255.255.255.0 into 255.x.x.x) which the GUI
// deliberately leaves legible. Worse, it was `internal`, so on Linux — where NetLightsHost
// is a separate target — the web server could not have called it even if it wanted to.
//
// Hand-rolled rather than NSRegularExpression: this has to run in the fully-static musl
// build, where plain stdlib string ops are the safer bet.
//
// CONTRACT (what privacy mode promises, per the in-app help):
//   masked   — IPv4 (first octet kept), IPv6 (first hextet kept), MAC (vendor OUI kept),
//              Wi-Fi SSID / network name, DNS search + split-DNS domains, user-named
//              network services.
//   intact   — loopback (127.x, ::1), broadcast/netmasks (255.x), the unspecified address
//              (0.x), and interface names (en0 / utun3 are non-identifying).

/// True for characters that can appear inside an IPv4/IPv6/MAC literal. Used to carve the
/// input into candidate runs; anything else terminates a run.
private func isAddressChar(_ c: Character) -> Bool {
    c.isHexDigit || c == "." || c == ":"
}

/// Mask the addresses inside an arbitrary display string, leaving all other text alone —
/// so the same helper works for node subtitles, gateway labels, table cells and tooltips.
/// A no-op when `on` is false, so callers can apply it unconditionally.
public func maskAddresses(_ s: String, _ on: Bool) -> String {
    guard on, !s.isEmpty else { return s }
    var out = ""
    var run = ""
    func flush() {
        if !run.isEmpty { out += maskAddressToken(run); run = "" }
    }
    for ch in s {
        if isAddressChar(ch) { run.append(ch) } else { flush(); out.append(ch) }
    }
    flush()
    return out
}

/// Mask one candidate run. Returns it unchanged when it isn't an address we redact —
/// which covers version strings ("1.9.2"), USB versions ("USB 2.1") and bare numbers,
/// none of which have the shape of an address.
private func maskAddressToken(_ t: String) -> String {
    // MAC — exactly six two-hex-digit groups. Keep the vendor OUI (the first three), which
    // identifies the manufacturer but not the machine.
    let colonParts = t.split(separator: ":", omittingEmptySubsequences: false)
    if colonParts.count == 6,
       colonParts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) {
        return colonParts.prefix(3).joined(separator: ":") + ":xx:xx:xx"
    }

    // IPv6 — a leading hextet and at least three colons, matching the GUI's old regex. That
    // deliberately excludes "::1" (two colons, no leading hextet), which stays legible for
    // the same reason 127.0.0.1 does.
    if t.contains(":") {
        let colons = t.filter { $0 == ":" }.count
        let head = String(t.prefix { $0 != ":" })
        if colons >= 3, !head.isEmpty, head.count <= 4, head.allSatisfy(\.isHexDigit) {
            return "\(head):\u{2022}\u{2022}"
        }
        return t
    }

    // IPv4 — four all-numeric octets. Loopback, broadcast/netmasks and the unspecified
    // address carry no identifying information and stay readable.
    let dotParts = t.split(separator: ".", omittingEmptySubsequences: false)
    guard dotParts.count == 4,
          dotParts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return t }
    if t.hasPrefix("127.") || t.hasPrefix("255.") || t.hasPrefix("0.") { return t }
    return "\(dotParts[0]).x.x.x"
}

/// A Wi-Fi SSID / network name names a home, office or coffee shop, so privacy mode
/// replaces it outright rather than masking part of it.
public func maskNetworkName(_ s: String, _ on: Bool) -> String {
    guard on, !s.isEmpty else { return s }
    return "\u{2022}\u{2022}\u{2022}\u{2022}"
}

/// DNS search / split-DNS match domains can name an employer or an internal network, so
/// privacy mode redacts the list while still reporting how many were hidden. Returns "—"
/// for an empty list, matching the tables' empty-cell convention.
public func maskDomainList(_ list: [String], _ on: Bool, separator: String = ", ") -> String {
    guard !list.isEmpty else { return "—" }
    if on { return "\u{2022}\u{2022}\u{2022} (\(list.count) hidden)" }
    return list.joined(separator: separator)
}

/// A user-named network service ("Acme-Corp VPN") can name an employer, so privacy mode
/// swaps it for the bound interface — which is non-identifying — or a generic label.
public func maskScopeLabel(_ label: String, interfaceName: String?,
                           userNamed: Bool, _ on: Bool) -> String {
    guard on, userNamed else { return label }
    return interfaceName ?? "(service)"
}

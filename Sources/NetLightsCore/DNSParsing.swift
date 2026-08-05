import Foundation

// Pure text parsers for the Linux DNS sources. They live in Core — not in the Linux
// collector — precisely because they are pure: that keeps them testable on any platform,
// against captured real-world output, instead of only being exercisable on a Linux box.
// The collector supplies the file contents; this file has no I/O.

/// One resolver scope discovered from the system.
public struct ResolverScope: Equatable, Sendable {
    public var label: String            // "enp0s1", "Global", "systemd-resolved stub"
    public var interfaceName: String?
    public var servers: [String]
    public var searchDomains: [String]
    public var isDefaultRoute: Bool     // this link answers queries that match nothing else
    public var currentServer: String?   // the one resolved is actually using, when known

    public init(label: String, interfaceName: String? = nil, servers: [String] = [],
                searchDomains: [String] = [], isDefaultRoute: Bool = false,
                currentServer: String? = nil) {
        self.label = label
        self.interfaceName = interfaceName
        self.servers = servers
        self.searchDomains = searchDomains
        self.isDefaultRoute = isDefaultRoute
        self.currentServer = currentServer
    }
}

/// Parse a `resolv.conf`. Handles `nameserver`, `search` and `domain`; ignores comments and
/// options. Used for both `/etc/resolv.conf` and the systemd/NetworkManager uplink files,
/// which share the format.
public func parseResolvConf(_ text: String) -> (servers: [String], search: [String]) {
    var servers: [String] = [], search: [String] = []
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count >= 2 else { continue }
        switch parts[0] {
        case "nameserver": servers.append(parts[1])
        case "search", "domain":
            // `search .` is systemd's "no search domains" placeholder, not a real domain.
            search.append(contentsOf: parts.dropFirst().filter { $0 != "." })
        default: break
        }
    }
    return (servers, search)
}

/// True when a resolver address is a local stub rather than a real upstream — the thing
/// that makes `/etc/resolv.conf` useless on a systemd-resolved box. `127.0.0.53` is
/// resolved's stub; `127.0.0.1`/`::1` are dnsmasq, unbound, a local BIND and friends.
public func isStubResolver(_ server: String) -> Bool {
    let s = server.split(separator: "%").first.map(String.init) ?? server   // strip %zone
    return s.hasPrefix("127.") || s == "::1"
}

/// Parse `resolvectl status`. Gives what the files cannot: which *link* each resolver
/// belongs to, which server is currently in use, and whether the link is the default route
/// for queries. Format (systemd 249+):
///
///     Link 2 (enp0s1)
///         Current Scopes: DNS
///     Current DNS Server: fe80::842f:57ff:fec8:1064
///            DNS Servers: 192.168.64.1 fe80::842f:57ff:fec8:1064
///             DNS Domain: corp.example ~lab.example
///          Default Route: yes
///
/// Values may wrap onto following indented lines, which is why continuation is tracked.
public func parseResolvectlStatus(_ text: String) -> [ResolverScope] {
    var scopes: [ResolverScope] = []
    var current: ResolverScope?
    var continuing: String?      // which multi-line field we're still reading

    func flush() {
        if let c = current, !c.servers.isEmpty || !c.searchDomains.isEmpty { scopes.append(c) }
        current = nil
    }

    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(raw)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continuing = nil; continue }

        // "Link 2 (enp0s1)" — start of a new link block.
        if trimmed.hasPrefix("Link "), let open = trimmed.firstIndex(of: "("),
           let close = trimmed.firstIndex(of: ")"), open < close {
            flush()
            let iface = String(trimmed[trimmed.index(after: open)..<close])
            current = ResolverScope(label: iface, interfaceName: iface)
            continuing = nil
            continue
        }
        if trimmed == "Global" { flush(); current = ResolverScope(label: "Global"); continuing = nil; continue }

        // A wrapped value: indented and carrying no "Key:" of its own.
        if !trimmed.contains(":"), let field = continuing, current != nil {
            let vals = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if field == "servers" { current?.servers.append(contentsOf: vals) }
            if field == "domains" { current?.searchDomains.append(contentsOf: vals.filter { $0 != "." }) }
            continue
        }

        guard let colon = trimmed.firstIndex(of: ":") else { continue }
        let key = trimmed[trimmed.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        let vals = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)

        switch key {
        case "DNS Servers":
            current?.servers.append(contentsOf: vals); continuing = "servers"
        case "DNS Domain":
            // A leading "~" marks a routing-only domain (split DNS), not a search suffix.
            current?.searchDomains.append(contentsOf: vals.filter { $0 != "." }); continuing = "domains"
        case "Current DNS Server":
            current?.currentServer = vals.first; continuing = nil
        case "Default Route":
            current?.isDefaultRoute = (value == "yes"); continuing = nil
        default:
            continuing = nil
        }
    }
    flush()
    return scopes
}

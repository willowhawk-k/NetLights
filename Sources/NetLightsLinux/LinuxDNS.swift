#if os(Linux)
import Foundation
import NetLightsCore

// L1 DNS collector — the global resolver set from /etc/resolv.conf (nameserver / search /
// domain). On systemd-resolved systems this is the stub (127.0.0.53); resolved's richer
// per-link upstreams (via resolvectl / D-Bus) are a later refinement. Read-only.
func linuxDNSConfigs() -> [DNSConfig] {
    guard let text = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) else { return [] }
    var servers: [String] = []
    var search: [String] = []
    for raw in text.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#") || line.hasPrefix(";") { continue }
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count >= 2 else { continue }
        switch parts[0] {
        case "nameserver":       servers.append(parts[1])
        case "search", "domain": search.append(contentsOf: parts.dropFirst())
        default:                 break
        }
    }
    guard !servers.isEmpty || !search.isEmpty else { return [] }
    return [DNSConfig(id: "global", scopeLabel: "Active resolvers",
                      servers: servers, searchDomains: search,
                      isPrimary: true, isGlobal: true)]
}
#endif

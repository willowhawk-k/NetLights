#if os(Linux)
import Foundation
import NetLightsCore

// Linux DNS collector.
//
// The first implementation read /etc/resolv.conf and stopped, which on any
// systemd-resolved system is a symlink to the STUB file holding 127.0.0.53 — a loopback
// address that says nothing about who actually answers queries. This answers the question
// people are really asking: what is *past* the stub?
//
// Sources, in order of usefulness. All read-only, none needs D-Bus, so this stays
// compatible with the fully-static musl build:
//
//   /run/systemd/resolve/resolv.conf   the real uplink servers (NOT stub-resolv.conf)
//   resolvectl status                  per-link attribution + which server is in use
//   /run/NetworkManager/resolv.conf    same idea on NetworkManager-without-resolved
//   /etc/resolv.conf                   last resort; often the stub
//
// The text parsing lives in Core (DNSParsing.swift) so it can be tested off-Linux against
// captured real output; this file is only I/O and assembly.

private func readFile(_ path: String) -> String? {
    try? String(contentsOfFile: path, encoding: .utf8)
}

/// `resolvectl status`, or nil when the binary is absent (non-systemd distro) or fails.
/// Degrade-absent: per-link detail is a bonus, never a requirement.
private func resolvectlStatus() -> String? {
    let candidates = ["/usr/bin/resolvectl", "/bin/resolvectl", "/usr/sbin/resolvectl"]
    guard let exe = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = ["status", "--no-pager"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
}

/// Same server can appear on several links; keep first-seen order (query order matters).
private func dedupePreservingOrder(_ xs: [String]) -> [String] {
    var seen = Set<String>()
    return xs.filter { seen.insert($0).inserted }
}

func linuxDNSConfigs() -> [DNSConfig] {
    var out: [DNSConfig] = []

    // What the C library will actually consult — often the stub, which is the whole problem.
    let systemFile = readFile("/etc/resolv.conf").map(parseResolvConf)
    let systemServers = systemFile?.servers ?? []
    let viaStub = !systemServers.isEmpty && systemServers.allSatisfy(isStubResolver)

    // The real upstreams, from whichever manager is present.
    let uplink = readFile("/run/systemd/resolve/resolv.conf").map(parseResolvConf)
        ?? readFile("/run/NetworkManager/resolv.conf").map(parseResolvConf)
    let links = resolvectlStatus().map(parseResolvectlStatus) ?? []

    // Prefer per-link data (it knows the interface); then the uplink file; then whatever
    // /etc/resolv.conf had, even if that turns out to be the stub.
    var upstreamServers = links.flatMap(\.servers)
    if upstreamServers.isEmpty { upstreamServers = uplink?.servers ?? [] }
    if upstreamServers.isEmpty { upstreamServers = systemServers }
    var upstreamSearch = links.flatMap(\.searchDomains)
    if upstreamSearch.isEmpty { upstreamSearch = uplink?.search ?? systemFile?.search ?? [] }

    // The headline set: servers that genuinely answer, not the loopback shim.
    if !upstreamServers.isEmpty || !upstreamSearch.isEmpty {
        out.append(DNSConfig(
            id: "global", scopeLabel: "Active resolvers",
            interfaceName: links.first(where: \.isDefaultRoute)?.interfaceName,
            servers: dedupePreservingOrder(upstreamServers),
            searchDomains: dedupePreservingOrder(upstreamSearch),
            isPrimary: true, isGlobal: true))
    }

    // Per-link scopes — which interface learned which resolvers, and the one in use.
    for link in links where !link.servers.isEmpty {
        var label = link.label
        if let cur = link.currentServer { label += "  (using \(cur))" }
        out.append(DNSConfig(
            id: "link:\(link.interfaceName ?? link.label)",
            scopeLabel: label,
            interfaceName: link.interfaceName,
            servers: link.servers,
            searchDomains: link.searchDomains,
            isPrimary: link.isDefaultRoute, isGlobal: false))
    }

    // Keep the stub visible rather than hiding it: it IS what the resolver library talks
    // to, and showing it explains why every other tool on the box reports 127.0.0.53.
    if viaStub {
        out.append(DNSConfig(
            id: "stub", scopeLabel: "Local stub (systemd-resolved)",
            servers: systemServers, searchDomains: [],
            isPrimary: false, isGlobal: false))
    }

    return out
}
#endif

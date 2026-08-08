import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#if canImport(NetLightsCore)
import NetLightsCore
#endif

// A tiny, dependency-free HTTP/1.1 server — the `serve` mode on every OS. Grew out of the
// Linux-only LinuxServer; the socket layer is now written to the three libcs we target
// (Darwin, Glibc, Musl), which differ in three specific ways called out inline below.
//
// No external packages, so the static musl binary stays dependency-free.
//
// SECURITY POSTURE: the payload is a full inventory of the machine's network — addresses,
// MACs, DNS servers, gateways, route table, device names. There is no authentication, so
// the default bind is LOOPBACK and anything routable is an explicit, warned opt-in. A
// Host-header allowlist blocks DNS rebinding, so a hostile web page in the user's browser
// can't read /snapshot.json off 127.0.0.1.

// Glibc types SOCK_STREAM as the `__socket_type` enum; Darwin and Musl give a plain Int32.
#if canImport(Glibc)
private let sockStream = Int32(SOCK_STREAM.rawValue)
#else
private let sockStream = SOCK_STREAM
#endif

public struct WebServer {
    public let bind: BindTarget
    public let port: UInt16
    public let pollMS: Int
    /// Called per request — the caller owns how expensive a snapshot is.
    public let collect: () -> TopologySnapshot
    /// Called once, AFTER the socket is bound and listening. `--open` uses this so the
    /// browser is never pointed at a port that failed to bind.
    public let onReady: (() -> Void)?

    public init(bind: BindTarget, port: UInt16, pollMS: Int = 1000,
                onReady: (() -> Void)? = nil,
                collect: @escaping () -> TopologySnapshot) {
        self.bind = bind
        self.port = port
        self.pollMS = pollMS
        self.onReady = onReady
        self.collect = collect
    }

    /// Snapshot cache. Every HTTP request used to run a FULL uncached gather — on macOS
    /// that means system_profiler per request, which the GUI and TUI both deliberately
    /// throttle. The browser polls once a second and asks for /snapshot.json and
    /// /graph.svg, so this was two full gathers per second.
    private final class Cache: @unchecked Sendable {
        var snapshot: TopologySnapshot?
        var takenAt: Double = -.infinity
    }
    private static let cache = Cache()

    /// Rates are derived SERVER-side now. The browser used to do it from successive polls,
    /// which meant the SVG was always rendered with an empty traffic map — so the graph
    /// never carried traffic emphasis, and (once hide-inactive existed) the engine would
    /// have considered every interface idle and hidden far too much.
    private final class Rates: @unchecked Sendable {
        var deriver = TrafficRateDeriver()
    }
    private static let rateBox = Rates()
    private static var rates: TrafficRateDeriver {
        get { rateBox.deriver }
        set { rateBox.deriver = newValue }
    }

    /// The snapshot as the web UI should see it: masked and/or filtered per the query.
    private func viewSnapshot(maxAge: Double, privacy: Bool, hide: Bool) -> TopologySnapshot {
        let snap = cachedSnapshot(maxAgeSeconds: maxAge)
        return redactedSnapshot(snap, rates: Self.rates, privacy: privacy, hideInactive: hide)
    }

    /// The pre-formatted table payload — see WebPresentation.swift for why it exists.
    private func uiJSON(maxAge: Double, privacy: Bool, hide: Bool) -> String {
        let snap = cachedSnapshot(maxAgeSeconds: maxAge)
        let payload = buildUIPayload(snap, rates: Self.rates, privacy: privacy, hideInactive: hide)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func cachedSnapshot(maxAgeSeconds: Double) -> TopologySnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        if let s = Self.cache.snapshot, now - Self.cache.takenAt < maxAgeSeconds { return s }
        let s = collect()
        Self.cache.snapshot = s
        Self.cache.takenAt = now
        // Sample rates once per COLLECT, never per request. Updating on a cache hit fed the
        // deriver the same counters again, which advanced its clock without advancing the
        // bytes — so with two tabs polling out of phase the next real delta was divided by a
        // short dt and the reported throughput ran high.
        Self.rates.update(s.interfaces)
        return s
    }

    /// Resolve the bind choice to a network-order IPv4. `.egress` asks the live snapshot
    /// which interface actually reaches the internet, then uses that interface's address.
    private func resolveAddress() -> (addr: in_addr_t, display: String)? {
        switch bind {
        case .loopback:
            var v = in_addr()
            _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &v) }
            return (v.s_addr, "127.0.0.1")
        case .all:
            return (in_addr_t(0), "0.0.0.0")   // INADDR_ANY
        case .literal(let s):
            var v = in_addr()
            guard "\(s)".withCString({ inet_pton(AF_INET, $0, &v) }) == 1 else { return nil }
            return (v.s_addr, s)
        case .egress:
            guard let ip = egressIPv4(in: collect()) else { return nil }
            var v = in_addr()
            guard ip.withCString({ inet_pton(AF_INET, $0, &v) }) == 1 else { return nil }
            return (v.s_addr, ip)
        }
    }

    /// Named hosts we'll answer to. IP-literal Hosts are handled separately (see
    /// `isAcceptableHost`) because enumerating every address this machine might be reached
    /// at is impossible when bound to 0.0.0.0.
    private func allowedHosts(_ display: String) -> Set<String> {
        ["localhost", "127.0.0.1", "[::1]", "::1", display]
    }

    /// Strip an optional `:port`. The port is deliberately NOT matched: the SSH tunnel this
    /// project recommends (`ssh -L 9000:localhost:8765`) arrives as `Host: localhost:9000`,
    /// which a port-exact allowlist rejects — breaking the very workflow the warning text
    /// tells people to use.
    private func hostWithoutPort(_ host: String) -> String {
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            return String(host[host.startIndex...close])       // [::1]:8765 -> [::1]
        }
        if host.filter({ $0 == ":" }).count == 1, let c = host.lastIndex(of: ":") {
            return String(host[host.startIndex..<c])
        }
        return host
    }

    /// A Host header that is a bare IP literal **cannot** be a DNS-rebinding attack:
    /// rebinding works by pointing a *hostname* at the target address, so with no name in
    /// play there is nothing to rebind. Rejecting IP literals therefore buys no safety and
    /// breaks the legitimate case — browsing `http://192.168.64.3:8765` from another
    /// machine after `--bind all`, where the allowlist only ever knew the literal
    /// "0.0.0.0" that no browser actually sends.
    ///
    /// Unknown *hostnames* are still refused, which is the case that matters.
    private func isIPLiteralHost(_ host: String) -> Bool {
        var h = host
        if h.hasPrefix("[") {                                  // [::1] or [::1]:8765
            guard let close = h.firstIndex(of: "]") else { return false }
            return h[h.index(after: h.startIndex)..<close].contains(":")
        }
        if h.filter({ $0 == ":" }).count == 1, let colon = h.lastIndex(of: ":") {
            h = String(h[h.startIndex..<colon])                // strip :port
        }
        return isIPv4Literal(h)
    }

    private func isAcceptableHost(_ host: String, allowed: Set<String>) -> Bool {
        if host.isEmpty { return true }
        let bare = hostWithoutPort(host)
        return allowed.contains(host) || allowed.contains(bare) || isIPLiteralHost(host)
    }

    public func run() -> Int32 {
        guard let (addr, display) = resolveAddress() else {
            FileHandle.standardError.write(Data("netlights: could not resolve --bind \(bind.label)\n".utf8))
            return 1
        }
        // A client that disappears mid-write would otherwise kill the process with SIGPIPE.
        // Darwin also offers SO_NOSIGPIPE per-socket, but ignoring it process-wide is the
        // one line that behaves identically on all three libcs.
        signal(SIGPIPE, SIG_IGN)

        let listenFD = socket(AF_INET, sockStream, 0)
        guard listenFD >= 0 else { perror("socket"); return 1 }
        defer { close(listenFD) }
        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var sa = sockaddr_in()
        #if canImport(Darwin)
        // BSD sockaddrs carry a length byte; Linux's do not. Omitting it works by luck on
        // some paths and not others — set it.
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_port = port.bigEndian
        sa.sin_addr.s_addr = addr

        let bound = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            FileHandle.standardError.write(Data(
                "netlights: cannot bind \(display):\(port) — \(String(cString: strerror(errno)))\n".utf8))
            return 1
        }
        guard listen(listenFD, 16) == 0 else { perror("listen"); return 1 }
        onReady?()          // bound and listening — only now is a browser URL meaningful

        // Report what we ACTUALLY bound to. Printing a loopback URL while listening on
        // 0.0.0.0 reads as "it ignored my --bind" — especially over SSH, where the user
        // can't see the socket.
        if bind.isRoutable {
            let what = bind == .all ? "\(display):\(port) (all interfaces)" : "\(display):\(port)"
            print("NetLights — listening on \(what)  (Ctrl-C to stop)")
            // Deliberately NOT resolving the LAN address for a friendlier URL: that needs a
            // snapshot, and on macOS a full gather runs system_profiler — which would stall
            // the banner for seconds before the user is told anything at all.
            print("   on this machine: http://127.0.0.1:\(port)")
            print("""

                  ⚠  Reachable from your network. This publishes your interfaces, IP and
                     MAC addresses, routes, DNS servers and device names, with NO
                     authentication. Use the default (--bind loopback) or an SSH tunnel
                     on any shared network.

                  """)
        } else {
            print("NetLights — serving on http://\(display):\(port)  (Ctrl-C to stop)")
        }
        // stdout is block-buffered when it isn't a terminal, so `netlights serve | tee log`
        // would otherwise show nothing until the buffer filled — i.e. never.
        fflush(stdout)
        let hosts = allowedHosts(display)
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 { continue }
            // The accept loop is single-threaded and blocking, so ANY client that connects
            // and never speaks would otherwise wedge the whole server for good — `nc host
            // 8765` and walk away, and the browser hangs forever. A receive/send deadline
            // bounds that to a few seconds. (Also fires for a half-open connection dropped
            // by a sleeping laptop, which is the accidental version of the same thing.)
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            handle(clientFD, allowedHosts: hosts)
            close(clientFD)
        }
    }

    private func handle(_ fd: Int32, allowedHosts: Set<String>) {
        // Read until the end of the header block. One read() is not enough: a request split
        // across packets (routine for a browser on a slow link) parsed as a truncated line,
        // yielding a bogus path or a missing Host. Capped so a peer can't stream forever.
        var raw = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 4096)
        while raw.count < 32_768 {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            raw.append(contentsOf: buf[0..<Int(n)])
            // Scan the RAW BYTES for the terminator. Decoding to a String first meant a
            // single non-UTF-8 byte anywhere in the request made the decode fail, so the
            // terminator was never seen and this single-threaded server stalled for the full
            // socket timeout on every such request — a trivial denial of service.
            if raw.count >= 4 {
                let n = raw.count
                var found = false
                var i = max(0, n - Int(4) - 4096)
                while i + 3 < n {
                    if raw[i] == 0x0D, raw[i+1] == 0x0A, raw[i+2] == 0x0D, raw[i+3] == 0x0A { found = true; break }
                    i += 1
                }
                if found { break }
            }
        }
        guard !raw.isEmpty else { return }
        let request = String(decoding: raw, as: UTF8.self)
        let lines = request.split(separator: "\r\n", omittingEmptySubsequences: false)
        let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        // Split the query off before dispatch. The switch below matches exact literals, so
        // with the raw target ANY url carrying a query — /graph.svg?w=1600, or even a plain
        // cache-buster — fell through to 404.
        let (path, query) = splitQuery(target)

        // DNS-rebinding guard: a hostile page can point its own hostname at 127.0.0.1 and
        // read this server from the user's browser. Requiring a known Host stops that.
        let host = lines.first(where: { $0.lowercased().hasPrefix("host:") })
            .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard isAcceptableHost(host, allowed: allowedHosts) else {
            respond(fd, status: "403 Forbidden", type: "text/plain", body: """
                unrecognized Host header: \(host)

                NetLights only answers to localhost, the address it is bound to, or a
                bare IP address — a guard against DNS rebinding. If you reached this
                by a hostname, use the machine's IP address instead.
                """)
            return
        }

        // Privacy and hide-inactive are resolved SERVER-side. For hide-inactive that's
        // forced — the graph is server-rendered SVG, so the browser can't filter it. For
        // privacy it's also the right call: `serve` has no authentication, so masking before
        // the bytes leave the process means a screen-share or a shoulder-surfer on the LAN
        // never sees the real addresses, rather than trusting the page not to render them.
        let privacy = query["privacy"] == "1"
        let hide = query["hide"] == "1"
        let maxAge = Double(pollMS) / 2000

        switch path {
        case "/snapshot.json":
            // Stays the raw TopologySnapshot — it's the documented `--dump-json` contract, so
            // no presentation fields and no schemaVersion churn. Only masking/filtering
            // apply, and only when asked for.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let snap = viewSnapshot(maxAge: maxAge, privacy: privacy, hide: hide)
            let body = (try? encoder.encode(snap))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            respond(fd, status: "200 OK", type: "application/json", body: body)
        case "/ui.json":
            // The presentation payload: every cell already formatted by the SAME Swift
            // helpers the app and the TUI use. The browser used to reimplement four
            // formatters and the route classifier in JS, and all four had drifted.
            respond(fd, status: "200 OK", type: "application/json",
                    body: uiJSON(maxAge: maxAge, privacy: privacy, hide: hide))
        case "/graph.svg":
            // w/h are the browser viewport, the equivalent of the app's GeometryReader.
            let w = clampDim(query["w"], fallback: 1200, lo: 640, hi: 6000)
            let h = clampDim(query["h"], fallback: 760, lo: 480, hi: 6000)
            let snap = cachedSnapshot(maxAgeSeconds: maxAge)
            respond(fd, status: "200 OK", type: "image/svg+xml; charset=utf-8",
                    body: renderGraphSVG(snapshot: snap, width: w, height: h,
                                         privacy: privacy, hideUnused: hide,
                                         trafficStates: Self.rates.allStates))
        case "/", "/index.html":
            respond(fd, status: "200 OK", type: "text/html; charset=utf-8",
                    body: Self.indexHTML(pollMS: pollMS))
        default:
            respond(fd, status: "404 Not Found", type: "text/plain", body: "not found")
        }
    }

    /// Split "/graph.svg?w=1600&h=900" into its path and decoded parameters.
    private func splitQuery(_ target: String) -> (String, [String: String]) {
        guard let q = target.firstIndex(of: "?") else { return (target, [:]) }
        let path = String(target[target.startIndex..<q])
        var params: [String: String] = [:]
        for pair in target[target.index(after: q)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let k = kv.first, !k.isEmpty else { continue }
            let v = kv.count > 1 ? String(kv[1]) : ""
            params[percentDecode(String(k))] = percentDecode(v)
        }
        return (path, params)
    }

    /// Minimal percent-decoding. `addingPercentEncoding`'s inverse is available on Foundation
    /// everywhere we build, but "+" as space is a form-encoding convention it doesn't handle.
    private func percentDecode(_ s: String) -> String {
        let plussed = s.replacingOccurrences(of: "+", with: " ")
        return plussed.removingPercentEncoding ?? plussed
    }

    /// Parse a viewport dimension, clamped so a hostile or fat-fingered value can't ask the
    /// layout engine for a 2-million-pixel canvas.
    private func clampDim(_ s: String?, fallback: Double, lo: Double, hi: Double) -> Double {
        guard let s, let v = Double(s), v.isFinite else { return fallback }
        return min(max(v, lo), hi)
    }

    private func respond(_ fd: Int32, status: String, type: String, body: String) {
        let bytes = Array(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\n"
            + "Content-Length: \(bytes.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
            + "X-Content-Type-Options: nosniff\r\n\r\n"
        Array(header.utf8).withUnsafeBytes { writeAll(fd, $0) }
        bytes.withUnsafeBytes { writeAll(fd, $0) }
    }

    private func writeAll(_ fd: Int32, _ buf: UnsafeRawBufferPointer) {
        guard let base = buf.baseAddress else { return }
        var sent = 0
        while sent < buf.count {
            let w = write(fd, base.advanced(by: sent), buf.count - sent)
            if w <= 0 { break }
            sent += w
        }
    }
}

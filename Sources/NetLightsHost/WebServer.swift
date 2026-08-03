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

    public init(bind: BindTarget, port: UInt16, pollMS: Int = 1000,
                collect: @escaping () -> TopologySnapshot) {
        self.bind = bind
        self.port = port
        self.pollMS = pollMS
        self.collect = collect
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

    /// Hosts we'll answer. Anything else is a rebinding attempt (or a proxy we don't serve).
    private func allowedHosts(_ display: String) -> Set<String> {
        var hosts: Set<String> = ["localhost", "127.0.0.1", "[::1]", "::1", display]
        for h in Array(hosts) { hosts.insert("\(h):\(port)") }
        return hosts
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
            handle(clientFD, allowedHosts: hosts)
            close(clientFD)
        }
    }

    private func handle(_ fd: Int32, allowedHosts: Set<String>) {
        var buf = [UInt8](repeating: 0, count: 8192)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return }
        let request = String(decoding: buf[0..<Int(n)], as: UTF8.self)
        let lines = request.split(separator: "\r\n", omittingEmptySubsequences: false)
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"

        // DNS-rebinding guard: a hostile page can point its own hostname at 127.0.0.1 and
        // read this server from the user's browser. Requiring a known Host stops that.
        let host = lines.first(where: { $0.lowercased().hasPrefix("host:") })
            .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard host.isEmpty || allowedHosts.contains(host) else {
            respond(fd, status: "403 Forbidden", type: "text/plain",
                    body: "unrecognized Host header")
            return
        }

        switch path {
        case "/snapshot.json":
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let body = (try? encoder.encode(collect()))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            respond(fd, status: "200 OK", type: "application/json", body: body)
        case "/graph.svg":
            respond(fd, status: "200 OK", type: "image/svg+xml; charset=utf-8",
                    body: renderGraphSVG(snapshot: collect()))
        case "/", "/index.html":
            respond(fd, status: "200 OK", type: "text/html; charset=utf-8",
                    body: Self.indexHTML(pollMS: pollMS))
        default:
            respond(fd, status: "404 Not Found", type: "text/plain", body: "not found")
        }
    }

    private func respond(_ fd: Int32, status: String, type: String, body: String) {
        let bytes = Array(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\n"
            + "Content-Length: \(bytes.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
            + "X-Content-Type-Options: nosniff\r\n\r\n"
        _ = Array(header.utf8).withUnsafeBytes { writeAll(fd, $0) }
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

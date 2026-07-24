import Foundation
import Network

/// Discovers the machine's PUBLIC IP as seen from a given egress, via a tiny STUN
/// (RFC 5389) binding request over UDP. Two uses:
///  - the DEFAULT route → the VPN-exit IP when a tunnel is up (what the world sees), and
///  - BOUND to a specific interface → the underlay / ISP IP, which bypasses a full-tunnel
///    VPN the same way split-tunnel excludes egress the physical carrier.
///
/// This is the app's ONLY active outbound query. It runs on demand from the "Reveal
/// external IP" button, never automatically — NetLights is otherwise 100% passive.
enum ExternalIPProbe {
    // Public STUN servers (UDP), unauthenticated. Tried in order until one answers.
    private static let servers: [(String, UInt16)] = [
        ("stun.l.google.com", 19302), ("stun1.l.google.com", 19302),
    ]

    /// Public IP as seen through the DEFAULT route (through the VPN tunnel if one is up).
    static func exitIP() async -> String? { await query(interfaceName: nil) }

    /// Public IP as seen EGRESSING a specific physical interface — the real underlay /
    /// ISP address, bypassing any full-tunnel VPN. nil if the interface is unknown.
    static func underlayIP(via interfaceName: String?) async -> String? {
        guard let interfaceName else { return nil }
        return await query(interfaceName: interfaceName)
    }

    private static func query(interfaceName: String?) async -> String? {
        let iface: NWInterface?
        if let interfaceName {
            guard let found = await interface(named: interfaceName) else { return nil }
            iface = found
        } else {
            iface = nil
        }
        for (host, port) in servers {
            // Resolve via the DEFAULT resolver first, then STUN to the IP literal. Binding
            // an NWConnection to a quiet/restricted carrier and letting IT resolve the
            // hostname stalls (DNS over that uplink may be blocked/absent) — pre-resolving
            // avoids that while the STUN packet itself still egresses the bound interface.
            guard let serverIP = await resolveIPv4(host) else { continue }
            if let ip = await stun(serverIP: serverIP, port: port, interface: iface) { return ip }
        }
        return nil
    }

    // MARK: - STUN exchange

    private static func stun(serverIP: String, port: UInt16, interface: NWInterface?) async -> String? {
        guard let addr = IPv4Address(serverIP) else { return nil }
        let params = NWParameters.udp
        if let interface { params.requiredInterface = interface }   // force egress via this uplink
        let conn = NWConnection(host: .ipv4(addr),
                                port: NWEndpoint.Port(rawValue: port)!, using: params)
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let once = ResumeBox(cont)
            let q = DispatchQueue(label: "netlights.stun")
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: request(), completion: .contentProcessed { _ in
                        conn.receiveMessage { data, _, _, _ in
                            let ip = data.flatMap { mappedAddress($0) }
                            conn.cancel()
                            once.resume(ip)
                        }
                    })
                case .failed, .cancelled:
                    once.resume(nil)
                default:
                    break
                }
            }
            q.asyncAfter(deadline: .now() + 3) { conn.cancel(); once.resume(nil) }   // timeout
            conn.start(queue: q)
        }
    }

    /// A 20-byte STUN Binding Request (magic cookie + random transaction id, no attributes).
    private static func request() -> Data {
        var d = Data([0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xA4, 0x42])
        for _ in 0..<12 { d.append(UInt8.random(in: 0...255)) }
        return d
    }

    /// Parse the IPv4 (XOR-)MAPPED-ADDRESS from a STUN success response.
    private static func mappedAddress(_ data: Data) -> String? {
        let b = [UInt8](data)
        guard b.count >= 20 else { return nil }
        let cookie: [UInt8] = [0x21, 0x12, 0xA4, 0x42]
        var i = 20   // attributes begin after the 20-byte header
        while i + 4 <= b.count {
            let type = UInt16(b[i]) << 8 | UInt16(b[i + 1])
            let len = Int(UInt16(b[i + 2]) << 8 | UInt16(b[i + 3]))
            let v = i + 4
            guard v + len <= b.count else { break }
            // 0x0020 XOR-MAPPED-ADDRESS (preferred), 0x0001 MAPPED-ADDRESS (legacy); family 0x01 = IPv4.
            if (type == 0x0020 || type == 0x0001), len >= 8, b[v + 1] == 0x01 {
                let xored = type == 0x0020
                let octets = (0..<4).map { xored ? b[v + 4 + $0] ^ cookie[$0] : b[v + 4 + $0] }
                return octets.map(String.init).joined(separator: ".")
            }
            i = v + len + ((4 - (len % 4)) % 4)   // attribute values are 4-byte aligned
        }
        return nil
    }

    /// Resolve a host to an IPv4 address via the DEFAULT resolver, off the main thread.
    private static func resolveIPv4(_ host: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            DispatchQueue.global().async {
                var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM,
                                     ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
                var res: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res,
                      let sa = first.pointee.ai_addr else {
                    if res != nil { freeaddrinfo(res) }
                    cont.resume(returning: nil); return
                }
                defer { freeaddrinfo(res) }
                var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
                cont.resume(returning: String(cString: buf))
            }
        }
    }

    // MARK: - Interface lookup

    /// The `NWInterface` for a BSD name (e.g. "en15"), from a one-shot path snapshot.
    private static func interface(named name: String) async -> NWInterface? {
        await withCheckedContinuation { (cont: CheckedContinuation<NWInterface?, Never>) in
            let once = ResumeBox(cont)
            let monitor = NWPathMonitor()
            let q = DispatchQueue(label: "netlights.pathsnap")
            monitor.pathUpdateHandler = { path in
                let iface = path.availableInterfaces.first { $0.name == name }
                monitor.cancel()
                once.resume(iface)
            }
            q.asyncAfter(deadline: .now() + 2) { monitor.cancel(); once.resume(nil) }
            monitor.start(queue: q)
        }
    }
}

/// Guards a `CheckedContinuation` so exactly one of {answer, failure, timeout} resumes it.
private final class ResumeBox<T> {
    private var cont: CheckedContinuation<T, Never>?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<T, Never>) { cont = c }
    func resume(_ v: T) { lock.lock(); defer { lock.unlock() }; cont?.resume(returning: v); cont = nil }
}

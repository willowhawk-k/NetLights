#if os(Linux)
import Foundation
import NetLightsCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// L3 Bluetooth collector: talk to BlueZ over the D-Bus system bus.
//
// This file is deliberately thin — connect, authenticate, two method calls, hand the bytes
// to Core. All the protocol lives in NetLightsCore/DBusWire.swift so it can be tested from
// macOS; all the model assembly lives in NetLightsCore/BlueZParsing.swift because
// AttachedDevice has no public init.
//
// DEGRADE-ABSENT, exhaustively: no socket file, connect refused, auth rejected, no org.bluez
// on the bus, adapter powered off, reply timeout, truncated or malformed reply — every one
// of these returns [] and none can block the snapshot. A machine with no Bluetooth at all is
// the common case, not an error.

// Glibc types SOCK_STREAM as an enum; Darwin and Musl give a plain Int32.
#if canImport(Glibc)
private let sockStream = Int32(SOCK_STREAM.rawValue)
#else
private let sockStream = SOCK_STREAM
#endif

/// Whole-exchange budget. SO_RCVTIMEO bounds each individual read, but a bus trickling one
/// byte just inside every timeout window could still stall forever, so the deadline is
/// checked between reads too.
private let totalDeadlineSeconds = 2.0
private let perCallTimeout = timeval(tv_sec: 1, tv_usec: 500_000)

private func monotonicNow() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
}

private final class BusConnection {
    let fd: Int32
    private let deadline: Double
    private var inbox: [UInt8] = []

    init?(_ address: DBusServerAddress) {
        guard let (sa, addrlen) = dbusSockaddrUn(address) else { return nil }
        let s = socket(AF_UNIX, sockStream, 0)
        guard s >= 0 else { return nil }

        // Non-blocking connect + poll: SO_SNDTIMEO does NOT bound connect(), and on AF_UNIX
        // it blocks when the server's accept backlog is full.
        let flags = fcntl(s, F_GETFL, 0)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        var ok = false
        sa.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: sockaddr.self, capacity: 1) { p in
                if connect(s, p, socklen_t(addrlen)) == 0 { ok = true; return }
                // A full accept backlog on AF_UNIX reports EAGAIN, not EINPROGRESS.
                guard errno == EINPROGRESS || errno == EAGAIN else { return }
                var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
                guard poll(&pfd, 1, 1500) > 0 else { return }
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0 else { return }
                ok = true
            }
        }
        guard ok else { close(s); return nil }
        _ = fcntl(s, F_SETFL, flags)

        var tv = perCallTimeout
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        self.fd = s
        self.deadline = monotonicNow() + totalDeadlineSeconds
    }

    deinit { close(fd) }

    var expired: Bool { monotonicNow() > deadline }

    /// MSG_NOSIGNAL, not write(): writing to a socket the bus has closed raises SIGPIPE and
    /// kills the process. WebServer ignores SIGPIPE process-wide, but this collector also
    /// runs under `tui` and `--dump-json`, where that handler was never installed.
    @discardableResult
    func send(_ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            if expired { return false }
            let n = bytes.withUnsafeBytes { raw -> Int in
                Glibcompat.send(fd, raw.baseAddress!.advanced(by: sent), bytes.count - sent)
            }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    private func fill() -> Bool {
        if expired { return false }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return false }
        inbox.append(contentsOf: buf[0..<n])
        return true
    }

    /// One CRLF-terminated SASL line.
    func readLine() -> String? {
        while true {
            if let i = inbox.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Array(inbox[..<i])
                inbox.removeFirst(i + 1)
                return String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard inbox.count < 8192, fill() else { return nil }
        }
    }

    /// One complete D-Bus message: read the 16-byte prefix, learn the total length from it,
    /// then read exactly that much. A reply routinely arrives across several reads.
    func readMessage() -> DBusMessage? {
        while inbox.count < 16 { guard fill() else { return nil } }
        guard let (total, _, _) = try? dbusExpectedLength(prefix: Array(inbox.prefix(16))),
              total > 0, total <= 16 * 1024 * 1024 else { return nil }
        while inbox.count < total { guard fill() else { return nil } }
        let msg = Array(inbox[..<total])
        inbox.removeFirst(total)
        return try? dbusDecodeMessage(msg)
    }

    /// Send a call and return the reply matched on REPLY_SERIAL.
    ///
    /// Matching on REPLY_SERIAL rather than the message serial is essential: right after
    /// Hello the bus emits a NameAcquired SIGNAL that carries serial 1 — the same serial as
    /// the Hello we just sent — so a naive `serial ==` test accepts the signal as the reply.
    func call(serial: UInt32, destination: String, path: String,
              interface: String?, member: String) -> DBusMessage? {
        guard send(dbusEncodeMethodCall(serial: serial, destination: destination, path: path,
                                        interface: interface, member: member)) else { return nil }
        while let msg = readMessage() {
            guard case .uint32(let replyTo)? = msg.fields[5]?.unwrapped, replyTo == serial else {
                continue                                   // a signal, or someone else's reply
            }
            // Type 3 is METHOD_ERROR — e.g. org.freedesktop.DBus.Error.ServiceUnknown when
            // BlueZ isn't running, which is an ordinary outcome, not a failure to report.
            return msg.type == .error ? nil : msg
        }
        return nil
    }
}

/// Wrapper so `send` isn't shadowed by the method of the same name.
private enum Glibcompat {
    static func send(_ fd: Int32, _ buf: UnsafeRawPointer, _ n: Int) -> Int {
        #if canImport(Musl)
        return Musl.send(fd, buf, n, Int32(MSG_NOSIGNAL))
        #else
        return Glibc.send(fd, buf, n, Int32(MSG_NOSIGNAL))
        #endif
    }
}

func linuxBluetoothDevices() -> [AttachedDevice] {
    let candidates = dbusSystemBusCandidates(env: ProcessInfo.processInfo.environment["DBUS_SYSTEM_BUS_ADDRESS"])
    for address in candidates {
        guard let bus = BusConnection(address) else { continue }

        // SASL: a mandatory bare NUL, then EXTERNAL auth (the daemon takes our uid from
        // SO_PEERCRED, so no credential passing is needed on Linux), then BEGIN.
        guard bus.send([0x00]),
              bus.send(dbusAuthExternalLine(uid: getuid())),
              let reply = bus.readLine(),
              case .ok = dbusParseAuthReply(reply),
              bus.send(Array("BEGIN\r\n".utf8)) else { continue }

        // Hello is mandatory before any other traffic; the bus refuses to route without it.
        guard bus.call(serial: 1, destination: "org.freedesktop.DBus",
                       path: "/org/freedesktop/DBus",
                       interface: "org.freedesktop.DBus", member: "Hello") != nil else { continue }

        guard let objects = bus.call(serial: 2, destination: "org.bluez", path: "/",
                                     interface: "org.freedesktop.DBus.ObjectManager",
                                     member: "GetManagedObjects") else { continue }

        // Pin the signature rather than trusting the one on the wire. A Swift trap is
        // UNCATCHABLE, so `try?` would not save the process from a malformed signature; and
        // decoding to a shape buildBluetoothDevices doesn't expect just yields nothing
        // useful anyway. If BlueZ ever answers with something else, that is a bug worth
        // showing as "no devices", not worth guessing at.
        guard objects.bodySignature == "a{oa{sa{sv}}}" else { continue }
        var reader = DBusReader(objects.body, littleEndian: objects.littleEndian)
        guard let tree = try? reader.read(objects.bodySignature) else { continue }
        return buildBluetoothDevices(managedObjects: tree)
    }
    return []
}
#endif

import Foundation

// The D-Bus wire protocol, hand-rolled.
//
// WHY THIS EXISTS. The Linux binary is a fully static musl executable — that single
// artifact running on every distro is the whole basis of the packaging plan. BlueZ, the
// only source of Bluetooth data on Linux, is reachable exclusively over D-Bus. Linking
// libdbus would forfeit the static property, so the choice was "no Bluetooth on Linux" or
// "write the protocol". This is the protocol: ~400 lines, zero dependencies.
//
// It lives in Core and is PURE — bytes in, values out — because there is no shell on any
// Linux machine here, so byte-vector fixtures asserted from macOS are the only test signal.
// Sources/NetLightsLinux/LinuxBluetooth.swift adds nothing but the socket.
//
// PROVENANCE: this marshaller was cross-checked against GLib's independent implementation
// (g_dbus_message_to_blob) and produces byte-identical output for the nested
// a{oa{sa{sv}}} body GetManagedObjects returns, in both directions.
//
// The two traps that cost the most if wrong, both pinned by fixtures rather than comments:
//   1. An ABSTRACT socket's addrlen must be 2 + 1 + strlen(name) — never
//      sizeof(sockaddr_un). Pass the full size and the kernel reads all 108 bytes as the
//      name, so connect() fails with ECONNREFUSED and nothing points at addrlen.
//   2. After Hello the bus sends a NameAcquired SIGNAL carrying serial 1 — the same serial
//      as our Hello. Matching on `serial ==` accepts the signal as the reply; the reply must
//      be matched on the REPLY_SERIAL header field.

public enum DBusValue: Equatable {
    case byte(UInt8)
    case boolean(Bool)
    case int16(Int16)
    case uint16(UInt16)
    case int32(Int32)
    case uint32(UInt32)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    case string(String)
    case objectPath(String)
    case signature(String)
    indirect case array(element: String, items: [DBusValue])
    indirect case structure([DBusValue])
    indirect case dictEntry(DBusValue, DBusValue)
    indirect case variant(DBusValue)
}

public enum DBusWireError: Error, Equatable {
    case truncated(need: Int, have: Int)
    case badSignature(String)
    case unsupportedType(UInt8)
    case depthExceeded
    case lengthExceeded(UInt32)
    case badBoolean(UInt32)
    case badEndianness(UInt8)
    case badProtocolVersion(UInt8)
    case notNulTerminated
    case badUTF8
}

// MARK: alignment

public func dbusAlignment(ofTypeCode c: UInt8) -> Int {
    switch c {
    case UInt8(ascii: "y"), UInt8(ascii: "g"), UInt8(ascii: "v"): return 1
    case UInt8(ascii: "n"), UInt8(ascii: "q"): return 2
    case UInt8(ascii: "b"), UInt8(ascii: "i"), UInt8(ascii: "u"),
         UInt8(ascii: "s"), UInt8(ascii: "o"), UInt8(ascii: "a"),
         UInt8(ascii: "h"): return 4
    case UInt8(ascii: "x"), UInt8(ascii: "t"), UInt8(ascii: "d"),
         UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "{"), UInt8(ascii: "}"): return 8
    default: return 1
    }
}

@inline(__always) func padTo(_ n: Int, _ a: Int) -> Int { (a - (n % a)) % a }

// MARK: writer

public struct DBusWriter {
    public private(set) var bytes: [UInt8]
    public let littleEndian: Bool
    public init(littleEndian: Bool = true, prefix: [UInt8] = []) {
        self.littleEndian = littleEndian; self.bytes = prefix
    }
    public mutating func align(_ a: Int) {
        bytes.append(contentsOf: [UInt8](repeating: 0, count: padTo(bytes.count, a)))
    }
    mutating func put<T: FixedWidthInteger>(_ v: T) {
        let x = littleEndian ? v.littleEndian : v.bigEndian
        withUnsafeBytes(of: x) { bytes.append(contentsOf: $0) }
    }
    public mutating func write(_ v: DBusValue) {
        switch v {
        case .byte(let b): bytes.append(b)
        case .boolean(let b): align(4); put(UInt32(b ? 1 : 0))
        case .int16(let n): align(2); put(n)
        case .uint16(let n): align(2); put(n)
        case .int32(let n): align(4); put(n)
        case .uint32(let n): align(4); put(n)
        case .int64(let n): align(8); put(n)
        case .uint64(let n): align(8); put(n)
        case .double(let d): align(8); put(d.bitPattern)
        case .string(let s), .objectPath(let s):
            let u = Array(s.utf8); align(4); put(UInt32(u.count))
            bytes.append(contentsOf: u); bytes.append(0)
        case .signature(let s):
            let u = Array(s.utf8); bytes.append(UInt8(u.count))
            bytes.append(contentsOf: u); bytes.append(0)
        case .array(let elem, let items):
            align(4)
            let lenIndex = bytes.count
            put(UInt32(0))                                  // placeholder
            align(dbusAlignment(ofTypeCode: Array(elem.utf8)[0]))
            let start = bytes.count                          // length counts from HERE
            for it in items { write(it) }
            let len = UInt32(bytes.count - start)
            let le = littleEndian ? len.littleEndian : len.bigEndian
            withUnsafeBytes(of: le) { raw in
                for (i, b) in raw.enumerated() { bytes[lenIndex + i] = b }
            }
        case .structure(let fields):
            align(8); for f in fields { write(f) }
        case .dictEntry(let k, let v2):
            align(8); write(k); write(v2)
        case .variant(let inner):
            write(.signature(dbusSignature(of: inner)))
            write(inner)
        }
    }
}

public func dbusSignature(of v: DBusValue) -> String {
    switch v {
    case .byte: return "y"
    case .boolean: return "b"
    case .int16: return "n"
    case .uint16: return "q"
    case .int32: return "i"
    case .uint32: return "u"
    case .int64: return "x"
    case .uint64: return "t"
    case .double: return "d"
    case .string: return "s"
    case .objectPath: return "o"
    case .signature: return "g"
    case .array(let e, _): return "a" + e
    case .structure(let f): return "(" + f.map(dbusSignature(of:)).joined() + ")"
    case .dictEntry(let k, let v2): return "{" + dbusSignature(of: k) + dbusSignature(of: v2) + "}"
    case .variant: return "v"
    }
}

// MARK: signature splitting

/// Split a signature into complete top-level single types.
public func dbusSplitSignature(_ sig: String) throws -> [String] {
    let s = Array(sig.utf8); var out: [String] = []; var i = 0
    while i < s.count {
        let start = i
        try skipOne(s, &i, depth: 0)
        out.append(String(decoding: s[start..<i], as: UTF8.self))
    }
    return out
}

func skipOne(_ s: [UInt8], _ i: inout Int, depth: Int) throws {
    guard depth < 32 else { throw DBusWireError.depthExceeded }
    guard i < s.count else { throw DBusWireError.badSignature("truncated") }
    let c = s[i]; i += 1
    switch c {
    case UInt8(ascii: "a"): try skipOne(s, &i, depth: depth + 1)
    case UInt8(ascii: "("):
        while i < s.count && s[i] != UInt8(ascii: ")") { try skipOne(s, &i, depth: depth + 1) }
        guard i < s.count else { throw DBusWireError.badSignature("unclosed (") }
        i += 1
    case UInt8(ascii: "{"):
        try skipOne(s, &i, depth: depth + 1); try skipOne(s, &i, depth: depth + 1)
        guard i < s.count, s[i] == UInt8(ascii: "}") else { throw DBusWireError.badSignature("unclosed {") }
        i += 1
    case UInt8(ascii: "y"), UInt8(ascii: "b"), UInt8(ascii: "n"), UInt8(ascii: "q"),
         UInt8(ascii: "i"), UInt8(ascii: "u"), UInt8(ascii: "x"), UInt8(ascii: "t"),
         UInt8(ascii: "d"), UInt8(ascii: "s"), UInt8(ascii: "o"), UInt8(ascii: "g"),
         UInt8(ascii: "v"), UInt8(ascii: "h"):
        break
    default: throw DBusWireError.unsupportedType(c)
    }
}

// MARK: reader

public struct DBusReader {
    public let bytes: [UInt8]
    public let littleEndian: Bool
    public private(set) var offset: Int
    public init(_ bytes: [UInt8], littleEndian: Bool = true, offset: Int = 0) {
        self.bytes = bytes; self.littleEndian = littleEndian; self.offset = offset
    }
    public mutating func align(_ a: Int) throws {
        let p = padTo(offset, a)
        guard offset + p <= bytes.count else { throw DBusWireError.truncated(need: offset + p, have: bytes.count) }
        offset += p
    }
    mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard offset + n <= bytes.count else { throw DBusWireError.truncated(need: offset + n, have: bytes.count) }
        defer { offset += n }
        return bytes[offset..<(offset + n)]
    }
    mutating func get<T: FixedWidthInteger>(_ t: T.Type) throws -> T {
        let n = MemoryLayout<T>.size
        try align(n == 8 ? 8 : n)
        let s = Array(try take(n))
        var v: T = 0
        withUnsafeMutableBytes(of: &v) { $0.copyBytes(from: s) }
        return littleEndian ? T(littleEndian: v) : T(bigEndian: v)
    }
    public mutating func read(_ signature: String, depth: Int = 0) throws -> DBusValue {
        guard depth < 32 else { throw DBusWireError.depthExceeded }
        let s = Array(signature.utf8)
        guard let c = s.first else { throw DBusWireError.badSignature("empty") }
        switch c {
        case UInt8(ascii: "y"): return .byte(Array(try take(1))[0])
        case UInt8(ascii: "b"):
            let u = try get(UInt32.self)
            guard u <= 1 else { throw DBusWireError.badBoolean(u) }
            return .boolean(u == 1)
        case UInt8(ascii: "n"): return .int16(try get(Int16.self))
        case UInt8(ascii: "q"): return .uint16(try get(UInt16.self))
        case UInt8(ascii: "i"): return .int32(try get(Int32.self))
        case UInt8(ascii: "u"), UInt8(ascii: "h"): return .uint32(try get(UInt32.self))
        case UInt8(ascii: "x"): return .int64(try get(Int64.self))
        case UInt8(ascii: "t"): return .uint64(try get(UInt64.self))
        case UInt8(ascii: "d"): return .double(Double(bitPattern: try get(UInt64.self)))
        case UInt8(ascii: "s"), UInt8(ascii: "o"):
            let n = Int(try get(UInt32.self))
            guard n <= 0x0400_0000 else { throw DBusWireError.lengthExceeded(UInt32(n)) }
            let body = Array(try take(n))
            let nul = Array(try take(1))[0]
            guard nul == 0 else { throw DBusWireError.notNulTerminated }
            let str = String(decoding: body, as: UTF8.self)
            return c == UInt8(ascii: "s") ? .string(str) : .objectPath(str)
        case UInt8(ascii: "g"):
            let n = Int(Array(try take(1))[0])
            let body = Array(try take(n))
            guard Array(try take(1))[0] == 0 else { throw DBusWireError.notNulTerminated }
            return .signature(String(decoding: body, as: UTF8.self))
        case UInt8(ascii: "v"):
            guard case .signature(let inner) = try read("g", depth: depth + 1) else { fatalError() }
            let parts = try dbusSplitSignature(inner)
            guard parts.count == 1 else { throw DBusWireError.badSignature(inner) }
            return .variant(try read(parts[0], depth: depth + 1))
        case UInt8(ascii: "a"):
            let elem = String(decoding: s[1...], as: UTF8.self)
            guard !elem.isEmpty else { throw DBusWireError.badSignature("a") }
            let len = try get(UInt32.self)
            guard len <= 0x0400_0000 else { throw DBusWireError.lengthExceeded(len) }
            try align(dbusAlignment(ofTypeCode: Array(elem.utf8)[0]))
            let start = offset
            let end = start + Int(len)
            guard end <= bytes.count else { throw DBusWireError.truncated(need: end, have: bytes.count) }
            var items: [DBusValue] = []
            while offset < end { items.append(try read(elem, depth: depth + 1)) }
            guard offset == end else { throw DBusWireError.badSignature("array overrun") }
            return .array(element: elem, items: items)
        case UInt8(ascii: "("):
            try align(8)
            let inner = String(decoding: s[1..<(s.count - 1)], as: UTF8.self)
            var fields: [DBusValue] = []
            for t in try dbusSplitSignature(inner) { fields.append(try read(t, depth: depth + 1)) }
            return .structure(fields)
        case UInt8(ascii: "{"):
            try align(8)
            let inner = String(decoding: s[1..<(s.count - 1)], as: UTF8.self)
            let parts = try dbusSplitSignature(inner)
            guard parts.count == 2 else { throw DBusWireError.badSignature(signature) }
            let k = try read(parts[0], depth: depth + 1)
            let v = try read(parts[1], depth: depth + 1)
            return .dictEntry(k, v)
        default: throw DBusWireError.unsupportedType(c)
        }
    }
}

// MARK: message

public enum DBusMessageType: UInt8 { case methodCall = 1, methodReturn = 2, error = 3, signal = 4 }

public let DBUS_MAX_MESSAGE_LENGTH = 134_217_728   // 2^27

public struct DBusMessage {
    public var type: DBusMessageType
    public var flags: UInt8
    public var serial: UInt32
    public var fields: [UInt8: DBusValue]
    public var bodySignature: String
    public var body: [UInt8]
    public var littleEndian: Bool
}

public func dbusEncodeMethodCall(serial: UInt32, destination: String, path: String,
                                 interface: String?, member: String,
                                 bodySignature: String = "", body: [DBusValue] = [],
                                 flags: UInt8 = 0) -> [UInt8] {
    // body marshalled standalone: the body always starts at an 8-aligned offset
    var bw = DBusWriter()
    for v in body { bw.write(v) }
    let bodyBytes = bw.bytes

    var fields: [(UInt8, DBusValue)] = [(1, .objectPath(path))]
    if let i = interface { fields.append((2, .string(i))) }
    fields.append((3, .string(member)))
    fields.append((6, .string(destination)))
    if !bodySignature.isEmpty { fields.append((8, .signature(bodySignature))) }
    fields.sort { $0.0 < $1.0 }

    var w = DBusWriter()
    w.write(.byte(UInt8(ascii: "l")))
    w.write(.byte(DBusMessageType.methodCall.rawValue))
    w.write(.byte(flags))
    w.write(.byte(1))
    w.write(.uint32(UInt32(bodyBytes.count)))
    w.write(.uint32(serial))
    w.write(.array(element: "(yv)", items: fields.map { .structure([.byte($0.0), .variant($0.1)]) }))
    w.align(8)
    var out = w.bytes
    out.append(contentsOf: bodyBytes)
    return out
}

/// From the first 16 bytes: (bodyLength, headerFieldArrayLength, totalLength).
public func dbusExpectedLength(prefix: [UInt8]) throws -> (total: Int, body: Int, endian: Bool) {
    guard prefix.count >= 16 else { throw DBusWireError.truncated(need: 16, have: prefix.count) }
    let le: Bool
    switch prefix[0] {
    case UInt8(ascii: "l"): le = true
    case UInt8(ascii: "B"): le = false
    default: throw DBusWireError.badEndianness(prefix[0])
    }
    guard prefix[3] == 1 else { throw DBusWireError.badProtocolVersion(prefix[3]) }
    func u32(_ o: Int) -> UInt32 {
        let b = prefix[o...(o + 3)].map(UInt32.init)
        return le ? (b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24)
                  : (b[3] | b[2] << 8 | b[1] << 16 | b[0] << 24)
    }
    let bodyLen = Int(u32(4)), fieldsLen = Int(u32(12))
    let total = 16 + fieldsLen + padTo(16 + fieldsLen, 8) + bodyLen
    guard total <= DBUS_MAX_MESSAGE_LENGTH, fieldsLen <= 0x0400_0000, bodyLen <= DBUS_MAX_MESSAGE_LENGTH
    else { throw DBusWireError.lengthExceeded(UInt32(truncatingIfNeeded: total)) }
    return (total, bodyLen, le)
}

public func dbusDecodeMessage(_ msg: [UInt8]) throws -> DBusMessage {
    let (total, bodyLen, le) = try dbusExpectedLength(prefix: Array(msg.prefix(16)))
    guard msg.count >= total else { throw DBusWireError.truncated(need: total, have: msg.count) }
    guard let type = DBusMessageType(rawValue: msg[1]) else { throw DBusWireError.unsupportedType(msg[1]) }
    var r = DBusReader(msg, littleEndian: le, offset: 4)
    _ = try r.get(UInt32.self)              // body length
    let serial = try r.get(UInt32.self)
    let arr = try r.read("a(yv)")
    var fields: [UInt8: DBusValue] = [:]
    if case .array(_, let items) = arr {
        for it in items {
            if case .structure(let f) = it, f.count == 2,
               case .byte(let code) = f[0], case .variant(let v) = f[1] { fields[code] = v }
        }
    }
    var sig = ""
    if case .signature(let s)? = fields[8] { sig = s }
    return DBusMessage(type: type, flags: msg[2], serial: serial, fields: fields,
                       bodySignature: sig, body: Array(msg[(total - bodyLen)..<total]),
                       littleEndian: le)
}

// MARK: SASL

public func dbusAuthExternalLine(uid: UInt32) -> [UInt8] {
    let hex = Array(String(uid).utf8).map { String(format: "%02x", $0) }.joined()
    return Array("AUTH EXTERNAL \(hex)\r\n".utf8)
}

public enum DBusAuthReply: Equatable {
    case ok(guid: String), rejected(mechanisms: [String]), data(String), error(String), agreeUnixFD, other(String)
}
public func dbusParseAuthReply(_ line: String) -> DBusAuthReply {
    let t = line.hasSuffix("\r\n") ? String(line.dropLast(2)) : line
    let parts = t.split(separator: " ", maxSplits: 1).map(String.init)
    switch parts.first ?? "" {
    case "OK": return .ok(guid: parts.count > 1 ? parts[1] : "")
    case "REJECTED": return .rejected(mechanisms: parts.count > 1 ? parts[1].split(separator: " ").map(String.init) : [])
    case "DATA": return .data(parts.count > 1 ? parts[1] : "")
    case "ERROR": return .error(parts.count > 1 ? parts[1] : "")
    case "AGREE_UNIX_FD": return .agreeUnixFD
    default: return .other(t)
    }
}

// MARK: address parsing

public struct DBusServerAddress: Equatable {
    public enum Kind: Equatable { case path(String), abstract(String) }
    public var kind: Kind
    public init(kind: Kind) { self.kind = kind }
}

func percentDecode(_ s: String) -> String? {
    var out: [UInt8] = []; let u = Array(s.utf8); var i = 0
    while i < u.count {
        if u[i] == UInt8(ascii: "%") {
            guard i + 2 < u.count,
                  let hi = hexVal(u[i + 1]), let lo = hexVal(u[i + 2]) else { return nil }
            out.append(hi << 4 | lo); i += 3
        } else { out.append(u[i]); i += 1 }
    }
    return String(decoding: out, as: UTF8.self)
}
func hexVal(_ c: UInt8) -> UInt8? {
    switch c {
    case 0x30...0x39: return c - 0x30
    case 0x41...0x46: return c - 0x41 + 10
    case 0x61...0x66: return c - 0x61 + 10
    default: return nil
    }
}

public func parseDBusAddresses(_ s: String) -> [DBusServerAddress] {
    var out: [DBusServerAddress] = []
    for entry in s.split(separator: ";", omittingEmptySubsequences: true) {
        guard let colon = entry.firstIndex(of: ":") else { continue }
        let transport = String(entry[entry.startIndex..<colon])
        guard transport == "unix" else { continue }
        var kv: [String: String] = [:]
        for pair in entry[entry.index(after: colon)...].split(separator: ",", omittingEmptySubsequences: true) {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let k = String(pair[pair.startIndex..<eq])
            guard let v = percentDecode(String(pair[pair.index(after: eq)...])) else { continue }
            kv[k] = v
        }
        if let p = kv["path"], !p.isEmpty { out.append(.init(kind: .path(p))) }
        else if let a = kv["abstract"], !a.isEmpty { out.append(.init(kind: .abstract(a))) }
    }
    return out
}


// MARK: - Reading values out of a decoded tree
//
// BlueZ property maps are `a{sv}`, so every property arrives wrapped in a variant. These
// accessors unwrap it and WIDEN unsigned integers: BlueZ picks a different width per
// property (Percentage is `y`, Appearance is `q`, Class is `u`), and a strict per-width
// accessor turns a type mismatch into a silently absent value — indistinguishable at
// runtime from "the device doesn't have that property", on a machine with no shell.

public extension DBusValue {
    /// Unwrap any depth of nested variants.
    var unwrapped: DBusValue {
        if case .variant(let inner) = self { return inner.unwrapped }
        return self
    }

    var asString: String? {
        switch unwrapped {
        case .string(let s), .objectPath(let s), .signature(let s): return s
        default: return nil
        }
    }

    var asBool: Bool? {
        if case .boolean(let b) = unwrapped { return b }
        return nil
    }

    /// Any integer widened to Int — deliberately lossy in width, never in value.
    var asInt: Int? {
        switch unwrapped {
        case .byte(let v):   return Int(v)
        case .uint16(let v): return Int(v)
        case .uint32(let v): return Int(v)
        case .uint64(let v): return v <= UInt64(Int.max) ? Int(v) : nil
        case .int16(let v):  return Int(v)
        case .int32(let v):  return Int(v)
        case .int64(let v):  return Int(v)
        default: return nil
        }
    }

    var asArray: [DBusValue]? {
        if case .array(_, let items) = unwrapped { return items }
        return nil
    }

    /// An array of DICT_ENTRY read as a string-keyed map. Unknown-shaped entries are skipped
    /// rather than failing: a newer daemon is free to add entries this build doesn't know.
    var asStringMap: [String: DBusValue]? {
        guard let items = asArray else { return nil }
        var out: [String: DBusValue] = [:]
        for item in items {
            guard case .dictEntry(let k, let v) = item, let key = k.asString else { continue }
            out[key] = v
        }
        return out
    }
}

// MARK: - sockaddr_un image
//
// Built here, in pure code, rather than in the Linux layer — the abstract-socket addrlen is
// the single most dangerous line in this collector and it fails in a way that points nowhere
// near the cause (connect() returns ECONNREFUSED). Producing the exact byte image on this
// side makes it assertable from macOS.

/// The Linux `sockaddr_un` image plus the `addrlen` to pass to connect(2).
///
/// Layout: 2-byte `sun_family` (AF_UNIX = 1) then 108 bytes of `sun_path`.
///   * filesystem — path bytes then a NUL; addrlen counts the NUL.
///   * abstract   — a LEADING NUL selects the abstract namespace, then the name, and there
///     is NO trailing NUL. addrlen = 2 + 1 + name. Passing sizeof(sockaddr_un) here makes
///     the kernel read all 108 bytes as the name, which matches nothing the server bound.
public func dbusSockaddrUn(_ address: DBusServerAddress) -> (bytes: [UInt8], addrlen: Int)? {
    var path = [UInt8](repeating: 0, count: 108)
    let addrlen: Int
    switch address.kind {
    case .path(let p):
        let b = Array(p.utf8)
        guard !b.isEmpty, b.count <= 107 else { return nil }   // path + NUL must fit
        path.replaceSubrange(0..<b.count, with: b)
        addrlen = 2 + b.count + 1
    case .abstract(let n):
        let b = Array(n.utf8)
        guard !b.isEmpty, b.count <= 107 else { return nil }   // leading NUL + name
        path.replaceSubrange(1..<(1 + b.count), with: b)
        addrlen = 2 + 1 + b.count
    }
    // AF_UNIX == 1, little-endian u16. Every architecture NetLights targets is LE.
    return ([1, 0] + path, addrlen)
}

/// The bus addresses to try, in order: the env override first, then both spellings of the
/// default socket (on most distros /var/run is a symlink to /run, but minimal containers
/// have only one).
public func dbusSystemBusCandidates(env: String?) -> [DBusServerAddress] {
    var out: [DBusServerAddress] = []
    if let e = env, !e.isEmpty { out = parseDBusAddresses(e) }
    for p in ["/var/run/dbus/system_bus_socket", "/run/dbus/system_bus_socket"] {
        let a = DBusServerAddress(kind: .path(p))
        if !out.contains(a) { out.append(a) }
    }
    return out
}

import Foundation

// The command-line contract, shared verbatim by every platform: macOS, Linux and
// (later) Windows all parse the SAME grammar here, so `netlights serve --port 9000`
// means the same thing everywhere. Foundation-only and free of `#if os(...)`: the
// platform's *default* mode (what a bare `netlights` does) is injected by the caller
// rather than baked in, because that is the one thing that legitimately differs —
// macOS opens the GUI, the headless Linux build serves.
//
// Hand-rolled rather than swift-argument-parser on purpose: the Mac App Store target
// builds from an Xcode project with zero package dependencies (it doesn't go through
// SwiftPM at all), SwiftUI's `App` already owns `@main` so ArgumentParser's ergonomics
// are unavailable anyway, the musl-static/nfpm packaging path is happiest with a
// dependency-free manifest — and ArgumentParser *errors* on unknown arguments, which is
// exactly wrong for a binary that is also a double-clickable .app (see `parse` below).

/// What `serve` should listen on. Defaults to loopback: the snapshot carries addresses,
/// MACs, DNS servers and device names, and the server has no authentication, so exposing
/// it to the network is an explicit, per-invocation choice.
public enum BindTarget: Equatable, Sendable {
    /// 127.0.0.1 — this machine only (the default).
    case loopback
    /// 0.0.0.0 — every interface, i.e. reachable by anything on the LAN.
    case all
    /// The primary uplink's own address, resolved from the live snapshot's egress.
    case egress
    /// A literal IPv4 address.
    case literal(String)

    /// How the choice reads in the startup banner.
    public var label: String {
        switch self {
        case .loopback:       return "127.0.0.1"
        case .all:           return "0.0.0.0"
        case .egress:        return "egress"
        case .literal(let s): return s
        }
    }

    /// True when the binding can be reached from off-machine — the banner warns for these.
    public var isRoutable: Bool {
        switch self {
        case .loopback:       return false
        case .all, .egress:   return true
        case .literal(let s): return !(s.hasPrefix("127.") || s == "::1")
        }
    }
}

public struct ServeOptions: Equatable, Sendable {
    public var port: UInt16 = 8765
    public var bind: BindTarget = .loopback
    public var openBrowser: Bool = false
    /// Browser poll cadence, milliseconds.
    public var pollMS: Int = 1000
    public init() {}
}

/// The TUI's views — same set, same order, and the same switch keys as the macOS tab bar
/// and the Linux web UI, so all three read as one product.
public enum TUIView: String, CaseIterable, Equatable, Sendable {
    case graph, routes, interfaces, devices, dns

    /// The key that selects this view (`g`/`r`/`i`/`d`/`n`); digits 1–5 work too.
    public var hotkey: Character {
        switch self {
        case .graph: return "g"
        case .routes: return "r"
        case .interfaces: return "i"
        case .devices: return "d"
        case .dns: return "n"
        }
    }

    public var title: String {
        switch self {
        case .graph: return "Graph"
        case .routes: return "Routes"
        case .interfaces: return "Interfaces"
        case .devices: return "Devices"
        case .dns: return "DNS"
        }
    }
}

public enum TUIColorMode: Equatable, Sendable {
    case none, ansi16, xterm256
}

public struct TUIOptions: Equatable, Sendable {
    public var interval: Double = 1.0
    public var initialView: TUIView = .graph
    /// User intent only — the driver still downgrades to `.none` when stdout isn't a TTY
    /// or `NO_COLOR` is set.
    public var color: Bool = true
    /// Render ONE frame to stdout and exit, without raw mode or the alt screen. Makes the
    /// dashboard usable non-interactively — in a pipe, a cron job, or a CI smoke test —
    /// which is otherwise impossible for a full-screen UI.
    public var once: Bool = false
    public init() {}
}

public enum NetLightsMode: Equatable, Sendable {
    case gui
    case tui(TUIOptions)
    case serve(ServeOptions)
    case dumpJSON(pretty: Bool)
    case help
    case version
}

public enum CLIParse: Equatable, Sendable {
    case ok(NetLightsMode)
    /// A usage error: one short line to stderr, then exit with this code. Never the help dump.
    case fail(message: String, code: Int32)
}

/// Tokens this parser will act on. Anything else — including no arguments at all, the
/// `-psn_…` / `-NSDocumentRevisionsDebugMode` pairs LaunchServices and Xcode inject, and
/// the app's own build-time flags (`--export-iconset`, `--probe-dump`) — falls through to
/// the platform default. That fallthrough is what keeps a double-clicked .app opening its
/// window instead of dying on a usage error, and it is why this parser is deliberately
/// permissive where a server-side CLI parser would be strict.
private let recognized: Set<String> = [
    "tui", "serve", "help", "version",
    "-h", "--help", "-V", "--version", "--dump-json",
]

/// Parse `argv` (including argv[0]). `defaultMode` is what a bare invocation means on this
/// platform — macOS passes `.gui`, the headless Linux build passes `.serve(...)`.
public func parseNetLightsCommandLine(_ argv: [String],
                                      default defaultMode: NetLightsMode) -> CLIParse {
    let args = Array(argv.dropFirst())
    guard let head = args.first, recognized.contains(head) else {
        return .ok(defaultMode)   // no args, or something we don't own — hand it back
    }
    let rest = Array(args.dropFirst())

    switch head {
    case "help", "-h", "--help":       return .ok(.help)
    case "version", "-V", "--version": return .ok(.version)
    case "--dump-json":
        var pretty = true
        for a in rest {
            if a == "--compact" { pretty = false }
            else { return .fail(message: "unknown option '\(a)' for --dump-json", code: 2) }
        }
        return .ok(.dumpJSON(pretty: pretty))
    case "tui":   return parseTUI(rest)
    case "serve": return parseServe(rest)
    default:      return .ok(defaultMode)
    }
}

/// Splits `--key=value` into its parts; returns nil when the token isn't in that form.
private func splitInline(_ token: String) -> (String, String)? {
    guard token.hasPrefix("--"), let eq = token.firstIndex(of: "=") else { return nil }
    return (String(token[token.startIndex..<eq]), String(token[token.index(after: eq)...]))
}

/// Pulls the value for an option, accepting both `--port 8765` and `--port=8765`.
private func takeValue(_ name: String, _ inline: String?,
                       _ args: [String], _ i: inout Int) -> String? {
    if let inline = inline { return inline }
    guard i + 1 < args.count else { return nil }
    i += 1
    return args[i]
}

private func parseTUI(_ args: [String]) -> CLIParse {
    var o = TUIOptions()
    var i = 0
    while i < args.count {
        let raw = args[i]
        let (name, inline) = splitInline(raw).map { ($0.0, Optional($0.1)) } ?? (raw, nil)
        switch name {
        case "--interval":
            guard let v = takeValue(name, inline, args, &i), let d = Double(v) else {
                return .fail(message: "--interval needs a number of seconds", code: 2)
            }
            guard d >= 0.1 && d <= 3600 else {
                return .fail(message: "--interval must be between 0.1 and 3600 seconds", code: 2)
            }
            o.interval = d
        case "--view":
            guard let v = takeValue(name, inline, args, &i), let view = TUIView(rawValue: v) else {
                return .fail(message: "--view must be one of: "
                             + TUIView.allCases.map(\.rawValue).joined(separator: ", "), code: 2)
            }
            o.initialView = view
        case "--no-color": o.color = false
        case "--once":     o.once = true
        default:
            return .fail(message: "unknown option '\(raw)' for 'tui' (try: netlights --help)", code: 2)
        }
        i += 1
    }
    return .ok(.tui(o))
}

private func parseServe(_ args: [String]) -> CLIParse {
    var o = ServeOptions()
    var i = 0
    while i < args.count {
        let raw = args[i]
        let (name, inline) = splitInline(raw).map { ($0.0, Optional($0.1)) } ?? (raw, nil)
        switch name {
        case "--port":
            guard let v = takeValue(name, inline, args, &i), let p = UInt16(v), p > 0 else {
                // 0 is "let the kernel choose", which would print an unusable URL.
                return .fail(message: "--port must be a number between 1 and 65535", code: 2)
            }
            o.port = p
        case "--bind":
            guard let v = takeValue(name, inline, args, &i) else {
                return .fail(message: "--bind needs an address (loopback, all, egress, or an IPv4 address)", code: 2)
            }
            switch v {
            case "loopback", "localhost", "127.0.0.1": o.bind = .loopback
            case "all", "0.0.0.0", "*":                o.bind = .all
            case "egress":                             o.bind = .egress
            default:
                guard isIPv4Literal(v) else {
                    return .fail(message: "--bind '\(v)' is not loopback, all, egress, or an IPv4 address", code: 2)
                }
                o.bind = .literal(v)
            }
        case "--interval":
            guard let v = takeValue(name, inline, args, &i), let d = Double(v) else {
                return .fail(message: "--interval needs a number of seconds", code: 2)
            }
            guard d >= 0.1 && d <= 3600 else {
                return .fail(message: "--interval must be between 0.1 and 3600 seconds", code: 2)
            }
            o.pollMS = Int(d * 1000)
        case "--open": o.openBrowser = true
        default:
            return .fail(message: "unknown option '\(raw)' for 'serve' (try: netlights --help)", code: 2)
        }
        i += 1
    }
    return .ok(.serve(o))
}

/// The IPv4 address of the interface that actually reaches the internet — what
/// `--bind egress` resolves to.
///
/// Lives in Core because `EgressInfo.viaInterface` and `InterfaceInfo.ipv4Addresses` are
/// internal; exposing one function keeps them that way rather than widening the model's
/// public surface for a single lookup (the same reasoning as `renderGraphSVG`).
public func egressIPv4(in snapshot: TopologySnapshot) -> String? {
    guard let via = snapshot.egress?.viaInterface else { return nil }
    return snapshot.interfaces.first { $0.id == via }?.ipv4Addresses.first
}

/// Dotted-quad check. Deliberately syntax-only — the bind itself is what validates that
/// the address actually exists on this machine.
public func isIPv4Literal(_ s: String) -> Bool {
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return false }
    for p in parts {
        guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isNumber), let n = Int(p), n <= 255
        else { return false }
    }
    return true
}

/// `netlights --help`. Hand-written (not generated) so the `--bind` block can explain the
/// exposure tradeoff, which is the one thing a user genuinely needs to understand here.
public let netLightsHelpText = """
NetLights — a live, layered map of your machine's network interfaces.

USAGE
  netlights                  Open the graphical app (default).
  netlights tui              Live terminal dashboard (top-style).
  netlights serve            Serve the web UI over HTTP.
  netlights --dump-json      Print one snapshot as JSON and exit.

COMMANDS
  tui        Full-screen live view. Switch views with
               g graph · r routes · i interfaces · d devices · n DNS
             (or 1-5); q or Ctrl-C quits. Requires a terminal.
  serve      Run the built-in web server and print its URL. Serves the
             same graph the app draws, plus /snapshot.json.

OPTIONS
  -h, --help           Show this help and exit.
  -V, --version        Show version information and exit.
      --dump-json      Print one snapshot as JSON to stdout and exit.
      --compact        --dump-json: emit compact rather than pretty JSON.
      --interval SEC   Refresh interval, 0.1-3600 (default 1.0).
      --view NAME      tui: start on graph|routes|interfaces|devices|dns.
      --once           tui: print one frame and exit (works without a
                       terminal — pipes, cron, CI).
      --no-color       tui: disable colour (NO_COLOR is honoured too).
      --port N         serve: TCP port to listen on (default 8765).
      --bind ADDR      serve: address to listen on (default loopback):
                         loopback  127.0.0.1 — this machine only
                         all       0.0.0.0 — every interface (LAN-visible)
                         egress    the primary uplink's own address
                         ADDRESS   a literal IPv4 address
      --open           serve: open the URL in the default browser.

NOTES
  serve exposes your interfaces, routes, DNS servers and gateway
  addresses with no authentication. Keep the default loopback bind, or
  use an SSH tunnel, on any shared network.

  https://github.com/willowhawk-k/NetLights
"""

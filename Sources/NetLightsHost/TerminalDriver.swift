import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
// On macOS the whole package compiles as ONE module, so Core's symbols are already in
// scope and there is no NetLightsCore module to import. On Linux Core is a real module.
#if canImport(NetLightsCore)
import NetLightsCore
#endif

// The only file in the project that touches termios/ioctl/poll/signal. Everything it
// draws comes from `renderTUIFrame` in Core, which is pure — so this stays small and the
// rendering stays testable without a terminal.
//
// Deliberately dependency-free (no ncurses): the Linux build is a fully-static musl
// binary, and linking ncurses would break that. Every primitive used here exists on
// Darwin, Glibc and Musl with identical Swift spelling.

// Saved terminal state. Allocated up front (never lazily) because the signal handler
// touches it, and a handler must not trigger Swift's lazy global initialization.
private let savedTermios = UnsafeMutablePointer<termios>.allocate(capacity: 1)
private var savedValid = false

/// Swift globals are initialised LAZILY (swift_once + malloc). A signal handler that is the
/// first thing to touch one would run that machinery in async-signal context — the classic
/// way a Ctrl-C leaves a terminal wedged. `primeSignalState()` forces every global the
/// handler needs into existence BEFORE any handler is installed.
private func primeSignalState() {
    _ = savedTermios
    _ = exitBuffer
    _ = exitSequence.count
}

/// Leave the alt screen, re-show the cursor, re-enable auto-wrap. Written as raw bytes so
/// the signal handler can emit it with a bare `write(2)`.
private let exitSequence = Array("\u{1B}[?25h\u{1B}[?7h\u{1B}[?1049l".utf8)
private let exitBuffer: UnsafeMutableRawPointer = {
    let p = UnsafeMutableRawPointer.allocate(byteCount: exitSequence.count, alignment: 1)
    p.copyMemory(from: exitSequence, byteCount: exitSequence.count)
    return p
}()

/// Restore using ONLY async-signal-safe calls (tcsetattr and write both qualify), so this
/// is equally valid from the main loop and from inside a signal handler.
private func restoreTerminal() {
    if savedValid { _ = tcsetattr(STDIN_FILENO, TCSANOW, savedTermios) }
    _ = write(STDOUT_FILENO, exitBuffer, exitSequence.count)
}

/// Restore, then re-raise with the default handler so the process still dies of the signal
/// it was sent (correct exit status, and the shell sees a real SIGINT). Handler-sets-a-flag
/// alone isn't enough: SIGTERM/SIGHUP can kill us before the loop notices, which is exactly
/// how a crashed TUI leaves someone's terminal in raw mode.
private func installSignalHandlers() {
    primeSignalState()   // never let a handler be the first to touch a lazy global
    for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
        signal(sig) { s in
            restoreTerminal()
            signal(s, SIG_DFL)
            raise(s)
        }
    }
    // Ctrl-Z: leave raw mode + alt screen before suspending, or the shell comes back to a
    // terminal that no longer echoes...
    signal(SIGTSTP) { s in
        restoreTerminal()
        signal(s, SIG_DFL)
        raise(s)
    }
    // ...and re-enter both on resume, or `fg` leaves the TUI running blind: cooked mode, on
    // the normal screen, keys echoing into a display that never repaints.
    signal(SIGCONT) { _ in
        _ = reenterRawModeAfterResume()
    }
    atexit { restoreTerminal() }
}

/// Raw-ish mode: clear ICANON (deliver keys immediately) and ECHO (don't print them), but
/// KEEP ISIG so Ctrl-C still raises SIGINT, and KEEP OPOST so "\n" still maps to CRLF.
/// `cfmakeraw` would clear both and force us to reimplement them.
private func enterRawMode() -> Bool {
    guard tcgetattr(STDIN_FILENO, savedTermios) == 0 else { return false }
    savedValid = true
    var raw = savedTermios.pointee
    raw.c_lflag &= ~(tcflag_t(ICANON) | tcflag_t(ECHO))
    // c_cc is imported as a tuple and can't be subscripted; rebind it. NCCS differs
    // between platforms (20 on Darwin, 32 on musl), so never hard-code the capacity.
    withUnsafeMutablePointer(to: &raw.c_cc) {
        $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
            cc[Int(VMIN)] = 0     // don't block waiting for a full line…
            cc[Int(VTIME)] = 1    // …but cap a read at 100ms as a safety net
        }
    }
    return tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0
}

/// Re-establish raw mode and the alt screen after SIGCONT (`fg`). Uses only
/// async-signal-safe calls, and the saved termios is already primed.
private func reenterRawModeAfterResume() -> Bool {
    guard savedValid else { return false }
    var raw = savedTermios.pointee
    raw.c_lflag &= ~(tcflag_t(ICANON) | tcflag_t(ECHO))
    withUnsafeMutablePointer(to: &raw.c_cc) {
        $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
            cc[Int(VMIN)] = 0
            cc[Int(VTIME)] = 1
        }
    }
    _ = tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    let enter = Array("\u{1B}[?1049h\u{1B}[?25l\u{1B}[?7l".utf8)
    _ = enter.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
    return true
}

/// Current terminal size, falling back to COLUMNS/LINES then 80x24 (a pipe or an odd CI pty).
private func terminalSize() -> (cols: Int, rows: Int) {
    var ws = winsize()
    if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 {
        return (Int(ws.ws_col), Int(ws.ws_row))
    }
    let env = ProcessInfo.processInfo.environment
    return (Int(env["COLUMNS"] ?? "") ?? 80, Int(env["LINES"] ?? "") ?? 24)
}

private func monotonicNow() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
}

private func clockLabel() -> String {
    var t = time(nil)
    var parts = tm()
    localtime_r(&t, &parts)
    return String(format: "%02d:%02d:%02d", parts.tm_hour, parts.tm_min, parts.tm_sec)
}

/// One `write(2)` per frame — no partial-frame tearing, and far cheaper than print().
private func writeAll(_ s: String) {
    let bytes = Array(s.utf8)
    var sent = 0
    bytes.withUnsafeBytes { buf in
        guard let base = buf.baseAddress else { return }
        while sent < buf.count {
            let n = write(STDOUT_FILENO, base.advanced(by: sent), buf.count - sent)
            if n <= 0 { break }
            sent += n
        }
    }
}

/// Pick a colour tier once at startup. NO_COLOR is honoured (no-color.org), and a
/// non-TTY stdout never gets escapes.
private func detectColorMode(userWantsColor: Bool) -> TUIColorMode {
    let env = ProcessInfo.processInfo.environment
    guard userWantsColor, env["NO_COLOR"] == nil, isatty(STDOUT_FILENO) == 1 else { return .none }
    let term = env["TERM"] ?? ""
    if term.isEmpty || term == "dumb" { return .none }
    if term.contains("256color") || env["COLORTERM"] != nil { return .xterm256 }
    return .ansi16
}

/// Box-drawing only when the locale actually says UTF-8 — minimal enterprise images
/// (exactly the RHEL/SLES targets) often boot with LANG=C, where they'd render as mojibake.
private func detectUnicode() -> Bool {
    let env = ProcessInfo.processInfo.environment
    let locale = env["LC_ALL"] ?? env["LC_CTYPE"] ?? env["LANG"] ?? ""
    return locale.uppercased().contains("UTF-8") || locale.uppercased().contains("UTF8")
}

public enum TUIRunResult {
    case ok
    case notATerminal
}

/// Run the interactive dashboard until the user quits. `collect` is called on the refresh
/// cadence — the caller decides how expensive that is (on macOS it should be the cheap
/// tier, not the full port/Bluetooth gather).
public func runTUI(options: TUIOptions,
                   versionLabel: String,
                   collect: () -> TopologySnapshot) -> TUIRunResult {
    let colorMode = detectColorMode(userWantsColor: options.color)
    let unicode = detectUnicode()

    // `--once`: one frame to stdout, no raw mode, no alt screen. Deliberately allowed
    // without a TTY — that's the point.
    if options.once {
        var state = TUIState()
        state.view = options.initialView
        var rates = TrafficRateDeriver()
        let snapshot = collect()
        rates.update(snapshot.interfaces, now: monotonicNow())
        // In a pipe there is no window size; the 24-row fallback silently TRUNCATED the
        // view. --once is a report, not a screen, so give it room and let the caller page.
        var size = terminalSize()
        if isatty(STDOUT_FILENO) != 1 { size.rows = 10_000 }
        let frame = TUIFrame(columns: size.cols, rows: size.rows,
                             colorMode: colorMode, unicode: unicode,
                             clockLabel: clockLabel(), versionLabel: versionLabel)
        let lines = renderTUIFrame(snapshot: snapshot, rates: rates, state: state, frame: frame)
        // Trailing blanks are layout padding for a fixed-height screen; pointless in a pipe.
        var trimmed = lines
        while let last = trimmed.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            trimmed.removeLast()
        }
        writeAll(trimmed.joined(separator: "\n") + "\n")
        return .ok
    }

    // A full-screen UI writing escape sequences into a pipe is the classic garbage-output
    // bug — refuse rather than emit it.
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else { return .notATerminal }

    guard enterRawMode() else { return .notATerminal }
    installSignalHandlers()
    writeAll("\u{1B}[?1049h\u{1B}[?25l\u{1B}[?7l")   // alt screen, hide cursor, no auto-wrap
    defer { restoreTerminal() }

    var state = TUIState()
    state.view = options.initialView
    var rates = TrafficRateDeriver()
    var snapshot = collect()
    rates.update(snapshot.interfaces, now: monotonicNow())

    var lastSample = monotonicNow()
    var lastSize = terminalSize()
    var dirty = true
    var running = true

    while running {
        let now = monotonicNow()

        if !state.paused, now - lastSample >= options.interval {
            snapshot = collect()
            rates.update(snapshot.interfaces, now: now)
            lastSample = now
            dirty = true
        }
        let size = terminalSize()
        if size != lastSize { lastSize = size; dirty = true }

        if dirty {
            let frame = TUIFrame(columns: size.cols, rows: size.rows,
                                 colorMode: colorMode, unicode: unicode,
                                 clockLabel: clockLabel(), versionLabel: versionLabel)
            let lines = renderTUIFrame(snapshot: snapshot, rates: rates,
                                       state: state, frame: frame)
            // Home, then each line self-erases to EOL, then clear anything below. This is
            // top(1)'s approach — no ESC[2J, so no flicker, and no cell-diffing engine
            // needed at ~20KB/frame.
            // No line terminator after the FINAL row: writing one scrolls the whole frame
            // up by a line, which silently ate the status header on every single frame.
            var out = "\u{1B}[H"
            let rows = Array(lines.prefix(size.rows))
            for (n, line) in rows.enumerated() {
                out += line + "\u{1B}[K"
                if n < rows.count - 1 { out += "\r\n" }
            }
            out += "\u{1B}[J"
            writeAll(out)
            dirty = false
        }

        // Sleep until the next tick, but wake early on a keypress.
        let msLeft = state.paused ? 250
            : max(1, Int((options.interval - (monotonicNow() - lastSample)) * 1000))
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, Int32(min(msLeft, 250)))
        if ready > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
            var buf = [UInt8](repeating: 0, count: 64)
            let n = read(STDIN_FILENO, &buf, buf.count)
            if n > 0 {
                // Decode the WHOLE buffer: a held key or a paste delivers several bytes,
                // and one CSI sequence spans 3-4. Coalesce, then render once.
                for key in decodeTUIKeys(buf[0..<n]) {
                    if !state.apply(key) { running = false; break }
                    dirty = true
                }
            }
        }
    }
    return .ok
}

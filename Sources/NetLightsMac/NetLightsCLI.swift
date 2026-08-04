import Foundation
import AppKit

// The macOS entry point. It exists so ONE binary can be both a double-clickable .app and a
// command-line tool: this runs before SwiftUI/AppKit boots, decides which it is, and hands
// off. `-parse-as-library` means the module can have no `main.swift` and exactly one type
// with `@main`, so `NetLightsApp` gave up its `@main` to this.
//
// SAFETY RULE — the reason this is an allowlist and not a parser: LaunchServices and Xcode
// inject arguments into GUI launches (`-psn_0_…`, `-NSDocumentRevisionsDebugMode YES`,
// `-ApplePersistenceIgnoreState`), and the release script drives the app with its own
// flags (`--export-iconset`, `--probe-dump`). ALL of those are `-`-prefixed. So only a
// bare word — which can only have come from a human typing it — is ever treated as a
// subcommand, and everything else falls through to the GUI exactly as it did before.
@main
enum NetLightsCLI {
    @MainActor
    static func main() {
        switch parseNetLightsCommandLine(CommandLine.arguments, default: .gui) {
        case .fail(let message, let code):
            FileHandle.standardError.write(Data("netlights: \(message)\n".utf8))
            exit(code)

        case .ok(let mode):
            switch mode {
            case .gui:
                relaunchViaLaunchServicesIfNeeded()   // exits if it hands off
                NetLightsApp.main()          // SwiftUI's entry point; never returns

            case .dumpJSON:
                // Deliberately NOT handled here. AppDelegate already implements it once
                // AppKit is up, which is what gives it display names and Bluetooth devices
                // (both need a WindowServer connection). Handling it early would silently
                // drop those fields from the cross-platform contract, so let it through.
                NetLightsApp.main()

            case .help:
                print(netLightsHelpText)
                exit(0)

            case .version:
                print("NetLights \(AppInfo.version) (\(AppInfo.build)) · \(AppInfo.releaseChannel)")
                exit(0)

            case .tui(let options):
                runTerminalUI(options)

            case .serve(let options):
                runWebServer(options)
            }
        }
    }

    // MARK: - GUI hand-off

    /// Typing `netlights` in a terminal should open the app exactly as double-clicking it
    /// does — but a process started by a shell stays *attributed to the shell*. macOS then
    /// refuses privacy-gated APIs on the terminal's behalf, and refusal here is fatal:
    /// touching IOBluetooth in that state is killed outright with
    /// `__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__`, even though the bundle declares the
    /// usage string. (Seen in the wild: the shipped 1.8.1 app crashes this way whenever it
    /// is launched from a shell.)
    ///
    /// So don't run the GUI in-process at all: ask LaunchServices to open the bundle, which
    /// starts a normally-attributed instance with full display and Bluetooth data, and exit.
    /// No relaunch loop is possible — the new process is LaunchServices-launched and takes
    /// the ordinary path.
    @MainActor
    private static func relaunchViaLaunchServicesIfNeeded() {
        guard !NetworkMonitor.launchedByLaunchServices else { return }
        let bundleURL = Bundle.main.bundleURL
        // `swift run` produces a bare executable with no .app to hand off to; run in-process
        // (the collector's guards keep that degraded-but-alive).
        guard bundleURL.pathExtension == "app" else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false

        // The completion arrives on a background queue and the run loop hasn't started, so
        // waiting here is safe.
        let done = DispatchSemaphore(value: 0)
        var handedOff = false
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { app, _ in
            handedOff = (app != nil)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
        if handedOff { exit(0) }
        // Hand-off failed — fall through and run in-process rather than doing nothing.
    }

    // MARK: - tui

    @MainActor
    private static func runTerminalUI(_ options: TUIOptions) {
        let monitor = NetworkMonitor()
        // Tier the gather like the GUI does: the cheap path every tick, the expensive
        // port/Bluetooth walk every ~3s, reusing the last result in between.
        var lastFull: TopologySnapshot?
        var lastFullAt = Date.distantPast

        // A terminal-launched process must not touch NSScreen or IOBluetooth: TCC blames
        // the responsible process (the shell), which has no usage description, and kills
        // us outright — see NetworkMonitor.launchedByLaunchServices. USB/Thunderbolt
        // devices still appear; display names and Bluetooth peripherals don't.
        let uiProbes = NetworkMonitor.launchedByLaunchServices

        let result = runTUI(options: options,
                            versionLabel: AppInfo.version) {
            let needsFull = Date().timeIntervalSince(lastFullAt) > 3.0
            if needsFull {
                let full = monitor.snapshot(includingPorts: true, allowUIProbes: uiProbes)
                lastFull = full
                lastFullAt = Date()
                return full
            }
            var snap = monitor.snapshot(includingPorts: false, allowUIProbes: uiProbes)
            // Carry the expensive tier forward so devices/power don't blink out between
            // full gathers.
            if let cached = lastFull {
                snap.hardwarePorts = cached.hardwarePorts
                snap.attachedDevices = cached.attachedDevices
                snap.systemPower = cached.systemPower
            }
            return snap
        }

        if result == .notATerminal {
            FileHandle.standardError.write(Data("""
                netlights: 'tui' needs an interactive terminal.
                Try 'netlights --dump-json' for a one-shot snapshot\
                \(AppInfo.isMacAppStoreBuild ? "." : ", or 'netlights serve' for the web UI.")

                """.utf8))
            exit(1)
        }
        exit(0)
    }

    // MARK: - serve

    @MainActor
    private static func runWebServer(_ options: ServeOptions) {
        // The App Store build is sandboxed WITHOUT com.apple.security.network.server
        // (ENABLE_INCOMING_NETWORK_CONNECTIONS = NO), so it cannot listen at all. The
        // server is compiled out of that build entirely rather than shipped as a stub
        // that always fails — a subcommand that exists but never works is worse for both
        // the user and App Review. The runtime receipt check is the same belt-and-braces
        // pattern AppInfo already uses for the donation link.
        #if APPSTORE
        FileHandle.standardError.write(Data("""
            netlights: 'serve' is not available in the Mac App Store build.
            The App Sandbox does not permit listening sockets. Download the
            Developer-ID build from https://github.com/willowhawk-k/NetLights/releases

            """.utf8))
        exit(2)
        #else
        if AppInfo.isMacAppStoreBuild {
            FileHandle.standardError.write(Data("netlights: 'serve' is unavailable in a sandboxed build.\n".utf8))
            exit(2)
        }
        let monitor = NetworkMonitor()
        let uiProbes = NetworkMonitor.launchedByLaunchServices   // see the tui note above
        let server = WebServer(bind: options.bind, port: options.port, pollMS: options.pollMS) {
            MainActor.assumeIsolated {
                monitor.snapshot(includingPorts: true, allowUIProbes: uiProbes)
            }
        }
        if options.openBrowser {
            let host = options.bind == .all ? "127.0.0.1" : options.bind.label
            if let url = URL(string: "http://\(host):\(options.port)") {
                NSWorkspace.shared.open(url)
            }
        }
        exit(server.run())
        #endif
    }
}

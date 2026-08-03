#if os(Linux)
import Foundation
import NetLightsCore
import NetLightsHost

// The Linux entry point. It parses the SAME grammar as macOS (see Core/CommandLine.swift)
// — `tui`, `serve --port/--bind`, `--dump-json` — so muscle memory carries between them.
// Guarded with `#if os(Linux)` so the macOS Xcode target (which sees all of Sources/)
// compiles this to nothing and doesn't trip over a second `@main`.
//
// The no-arg default is `serve`, because this build has no window yet. Once the native
// WebKitGTK window lands (Part 2 of the port) that becomes `.gui` — a one-line change
// here, not in Core.
@main
struct NetLightsLinuxMain {
    static func main() {
        let collector = LinuxCollector()

        switch parseNetLightsCommandLine(CommandLine.arguments, default: .serve(ServeOptions())) {
        case .fail(let message, let code):
            FileHandle.standardError.write(Data("netlights: \(message)\n".utf8))
            exit(code)

        case .ok(let mode):
            switch mode {
            case .help:
                print(netLightsHelpText)

            case .version:
                print("NetLights \(netLightsVersion) · Linux")

            case .gui, .dumpJSON:
                // No window on Linux yet, so `.gui` can't arrive via the default above —
                // but if that default ever changes, a JSON dump is a more useful fallback
                // than doing nothing.
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? encoder.encode(collector.snapshot()),
                   let json = String(data: data, encoding: .utf8) {
                    print(json)
                } else {
                    FileHandle.standardError.write(Data("netlights: failed to encode snapshot\n".utf8))
                    exit(1)
                }

            case .tui(let options):
                let result = runTUI(options: options, versionLabel: netLightsVersion) {
                    collector.snapshot()
                }
                if result == .notATerminal {
                    FileHandle.standardError.write(Data("""
                        netlights: 'tui' needs an interactive terminal.
                        Try 'netlights --dump-json', or 'netlights serve' for the web UI.

                        """.utf8))
                    exit(1)
                }

            case .serve(let options):
                let server = WebServer(bind: options.bind, port: options.port,
                                       pollMS: options.pollMS) { collector.snapshot() }
                exit(server.run())
            }
        }
    }
}
#endif

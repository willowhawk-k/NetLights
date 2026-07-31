#if os(Linux)
import Foundation
import NetLightsCore

// Entry point. Default: run the local web server (open it in a browser). `--dump-json`:
// print one snapshot and exit. Guarded with `#if os(Linux)` so the macOS Xcode target
// (which sees all of Sources/) compiles this to nothing.
@main
struct NetLightsLinuxMain {
    static func main() {
        let args = CommandLine.arguments

        if args.contains("--dump-json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(LinuxCollector().snapshot()),
               let json = String(data: data, encoding: .utf8) {
                print(json)
            } else {
                FileHandle.standardError.write(Data("netlights-linux: failed to encode snapshot\n".utf8))
            }
            return
        }

        // Optional `--port N` (default 8765).
        var port: UInt16 = 8765
        if let i = args.firstIndex(of: "--port"), i + 1 < args.count, let p = UInt16(args[i + 1]) {
            port = p
        }
        LinuxServer(host: "0.0.0.0", port: port).run()
    }
}
#endif

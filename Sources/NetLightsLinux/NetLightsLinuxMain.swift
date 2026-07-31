#if os(Linux)
import Foundation
import NetLightsCore

// L0 entry point. For now it just gathers a (stub) snapshot and can emit it as JSON —
// proving the portable Core compiles and runs as a separate module on Linux. The web
// renderer + `serve` mode arrive in L2. Guarded with `#if os(Linux)` so the macOS Xcode
// target (which sees all of Sources/) compiles this to nothing.
@main
struct NetLightsLinuxMain {
    static func main() {
        let snapshot = LinuxCollector().snapshot()

        if CommandLine.arguments.contains("--dump-json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(snapshot),
               let json = String(data: data, encoding: .utf8) {
                print(json)
            } else {
                FileHandle.standardError.write(Data("netlights-linux: failed to encode snapshot\n".utf8))
            }
            return
        }

        print("netlights-linux \(snapshot.schemaVersion) — machineModel: \(snapshot.machineModel)")
        print("  interfaces: \(snapshot.interfaces.count)  routes: \(snapshot.routes.count)  gateways: \(snapshot.gateways.count)")
        print("  (L0 stub — real collectors land in L1, the web renderer in L2. Try --dump-json.)")
    }
}
#endif

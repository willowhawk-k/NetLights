// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Source layout for the cross-platform port:
//   Sources/NetLightsCore  — portable, Foundation-only (models, TopologySnapshot, the
//                            layout engine, normalization). A standalone library on Linux.
//   Sources/NetLightsMac   — macOS UI (SwiftUI/AppKit) + acquisition (IOKit/CoreWLAN/…).
//   Sources/NetLightsLinux — the Linux executable (collector + web renderer).
//
// On macOS, Core + Mac compile as ONE executable module (no import/public boundary needed
// for the app itself). The real module split materializes for the LINUX build, where
// NetLightsCore is a separate library and NetLightsMac isn't built at all.
//
// The manifest is HOST-evaluated, so `#if os(macOS)` alone can't tell a native-Mac build
// from a Mac-hosted cross-compile to Linux. Set NETLIGHTS_LINUX=1 to force the Linux
// package when cross-compiling from a Mac, e.g.:
//   NETLIGHTS_LINUX=1 swift build -c release --swift-sdk aarch64-swift-linux-musl
let forceLinux = ProcessInfo.processInfo.environment["NETLIGHTS_LINUX"] != nil
#if os(macOS)
let buildLinux = forceLinux
#else
let buildLinux = true
#endif

let package: Package
if buildLinux {
    package = Package(
        name: "NetLights",
        targets: [
            .target(name: "NetLightsCore", path: "Sources/NetLightsCore"),
            // Host-platform services: the libc-touching layer (termios terminal driver +
            // the BSD-socket web server). Split out so NetLightsCore stays Foundation-only
            // — the portability guardrail. Compiles on Darwin, Glibc and Musl alike.
            .target(name: "NetLightsHost",
                    dependencies: ["NetLightsCore"],
                    path: "Sources/NetLightsHost"),
            .executableTarget(
                name: "netlights-linux",
                dependencies: ["NetLightsCore", "NetLightsHost"],
                path: "Sources/NetLightsLinux",
                swiftSettings: [.unsafeFlags(["-parse-as-library"])]
            ),
        ]
    )
} else {
    package = Package(
        name: "NetLights",
        platforms: [.macOS(.v13)],
        targets: [
            .executableTarget(
                name: "NetLights",
                path: "Sources",
                exclude: ["NetLightsLinux"],
                swiftSettings: [.unsafeFlags(["-parse-as-library"])]
            ),
        ]
    )
}

// swift-tools-version: 5.9
import PackageDescription

// Source layout is split for the cross-platform port:
//   Sources/NetLightsCore  — portable, no platform frameworks (models, snapshot, the
//                            layout engine, normalization). Becomes its own library
//                            target on Linux; a future Linux executable imports it.
//   Sources/NetLightsMac   — macOS UI (SwiftUI/AppKit) + data acquisition (IOKit,
//                            sysctl, SystemConfiguration, CoreWLAN, IOBluetooth).
//
// On macOS the two are compiled together as ONE module (this single executable
// target), so no `import`/`public` boundary is needed here and the Mac App Store
// Xcode target stays a single app target too. The real module split (NetLightsCore as
// a separate library) materializes on Linux, where NetLightsMac isn't built at all.
let package = Package(
    name: "NetLights",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "NetLights",
            path: "Sources",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)

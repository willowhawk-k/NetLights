// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NetLights",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "NetLights",
            path: "Sources/NetLights",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)

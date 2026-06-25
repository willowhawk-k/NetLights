import Foundation

/// Central place for product metadata shown in the About / Help windows.
enum AppInfo {
    static let name     = "NetLights"
    static let tagline  = "A live, layered map of your Mac's network interfaces."

    // Version lives in Version.xcconfig (single source of truth for both release
    // channels) and reaches the bundle's Info.plist at build time; read it back at
    // runtime so the About/Help screen always matches the binary. Falls back to
    // "dev" under `swift run`, where there's no packaged Info.plist.
    private static func plist(_ key: String) -> String? {
        Bundle.main.infoDictionary?[key] as? String
    }
    static let version     = plist("CFBundleShortVersionString") ?? "dev"
    static let build       = plist("CFBundleVersion") ?? "0"
    static let releaseDate = plist("NLReleaseDate") ?? ""

    static let author   = "Keith Willowhawk"
    static let year     = "2026"

    /// Short credit line shown in About.
    static let coauthor = "Pair-programmed with Claude (Anthropic)"

    static let sponsorURL   = "https://github.com/sponsors/willowhawk-k"
    static let sponsorTitle = "Support free software (because tacos and coffee run the world!)"

    /// Deep link to System Settings ▸ Privacy & Security ▸ Location Services.
    static let locationSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"

    static var versionString: String {
        "Version \(version) (\(build))" + (releaseDate.isEmpty ? "" : " · \(releaseDate)")
    }
    static var copyright: String { "© \(year) \(author)" }
}

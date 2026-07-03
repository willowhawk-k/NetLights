import Foundation

/// Central place for product metadata shown in the About / Help windows.
enum AppInfo {
    static let name     = "NetLights"
    static let tagline  = "A live, layered map of your Mac's network interfaces."

    /// Whether to hide the in-app donation (GitHub Sponsors) link. The Mac App Store
    /// forbids linking out to external donation mechanisms — guideline 3.1.1 requires
    /// donations to go through In-App Purchase — so the App Store build omits it while
    /// the Developer-ID / GitHub build keeps it. Driven by the APPSTORE compile flag
    /// (set in the Xcode target's Active Compilation Conditions) with a runtime
    /// Mac-App-Store-receipt check as a fail-safe, so a mis-configured build still
    /// can't ship the donation link through the Store.
    static var isMacAppStoreBuild: Bool {
        guard let receipt = Bundle.main.appStoreReceiptURL else { return false }
        return FileManager.default.fileExists(atPath: receipt.path)
    }
    static var hideDonations: Bool {
        #if APPSTORE
        return true
        #else
        return isMacAppStoreBuild
        #endif
    }

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

    static let repoURL      = "https://github.com/willowhawk-k/NetLights"
    static let sponsorURL   = "https://github.com/sponsors/willowhawk-k"
    static let sponsorTitle = "Support free software (because tacos and coffee run the world!)"

    /// Deep link to System Settings ▸ Privacy & Security ▸ Location Services.
    static let locationSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"

    /// Deep link to System Settings ▸ Privacy & Security ▸ Bluetooth.
    static let bluetoothSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"

    static var versionString: String {
        "Version \(version) (\(build))" + (releaseDate.isEmpty ? "" : " · \(releaseDate)")
    }
    static var copyright: String { "© \(year) \(author)" }
}

import Foundation

/// Central place for product metadata shown in the About / Help windows.
enum AppInfo {
    static let name     = "NetLights"
    static let tagline  = "A live, layered map of your Mac's network interfaces."
    static let version  = "1.2.0"
    static let build    = "3"
    static let releaseDate = "June 13, 2026"

    static let author   = "Keith Willowhawk"
    static let year     = "2026"

    /// Short credit line shown in About.
    static let coauthor = "Pair-programmed with Claude (Anthropic)"

    static var versionString: String { "Version \(version) (\(build)) · \(releaseDate)" }
    static var copyright: String { "© \(year) \(author)" }
}

import Foundation

/// The version string for builds that have no Info.plist to read — i.e. Linux, and
/// `swift run` on macOS. The packaged macOS app prefers `AppInfo.version`, which reads the
/// bundle, so this is never the authority there.
///
/// ⚠ `Version.xcconfig` at the repo root remains the single source of truth for released
/// builds; keep this in step with its `MARKETING_VERSION` when cutting a release. (It
/// can't simply read the xcconfig: SwiftPM manifests are evaluated on the host and this
/// value has to survive into a fully-static cross-compiled binary.)
public let netLightsVersion = "1.9.0"

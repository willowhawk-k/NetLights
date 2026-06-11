import SwiftUI
import AppKit

/// Build-time asset generation, reusing the in-app SwiftUI icon. Runs via a
/// hidden launch flag (see AppDelegate) so the release packaging script can
/// produce a real .icns without any external image tools.
enum AssetExport {

    /// Writes a full macOS .iconset directory (all required sizes) from AppIconView.
    @MainActor
    static func writeIconset(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // (point size, @2x?) → filename per Apple's iconset convention.
        let specs: [(Int, Bool)] = [(16,false),(16,true),(32,false),(32,true),
                                     (128,false),(128,true),(256,false),(256,true),
                                     (512,false),(512,true)]
        for (pt, retina) in specs {
            let px = CGFloat(pt) * (retina ? 2 : 1)
            let name = "icon_\(pt)x\(pt)\(retina ? "@2x" : "").png"
            writePNG(of: AppIconView(), pixels: px, to: dir.appendingPathComponent(name))
        }
    }

    /// Renders a SwiftUI view to a PNG at an exact pixel size.
    @MainActor
    static func writePNG<V: View>(of view: V, pixels: CGFloat, to url: URL) {
        let renderer = ImageRenderer(content: view.frame(width: pixels, height: pixels))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: pixels, height: pixels)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    /// Handles `--export-*` launch flags; returns true if the app should exit.
    @MainActor
    static func handleLaunchFlags(_ args: [String]) -> Bool {
        if let i = args.firstIndex(of: "--export-iconset"), i + 1 < args.count {
            writeIconset(to: URL(fileURLWithPath: args[i + 1]))
            return true
        }
        return false
    }
}

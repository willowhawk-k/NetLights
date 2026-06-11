import SwiftUI
import AppKit

/// A stylized, neon/synthwave "network port light" used as the app icon and
/// shown on the About screen. Drawn entirely in SwiftUI so it stays crisp at
/// any size and can be rasterized to an NSImage for the dock icon at runtime.
struct AppIconView: View {
    /// 0…1 design canvas; all geometry is expressed as fractions of `side`.
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                background(s)
                speedStreaks(s)
                port(s)
            }
            .frame(width: s, height: s)
            .clipShape(RoundedRectangle(cornerRadius: s * 0.22, style: .continuous))
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: - Layers

    private func background(_ s: CGFloat) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.13, green: 0.05, blue: 0.30),
                         Color(red: 0.36, green: 0.08, blue: 0.42),
                         Color(red: 0.05, green: 0.10, blue: 0.32)],
                startPoint: .topLeading, endPoint: .bottomTrailing)

            // Neon horizon glow
            RadialGradient(
                colors: [Color(red: 1.0, green: 0.35, blue: 0.7).opacity(0.55), .clear],
                center: .init(x: 0.5, y: 0.78), startRadius: 0, endRadius: s * 0.7)

            // Synthwave grid floor
            gridFloor(s)
        }
    }

    private func gridFloor(_ s: CGFloat) -> some View {
        Canvas { ctx, size in
            let horizon = size.height * 0.66
            var grid = Path()
            // Horizontal lines receding to the horizon
            var y = horizon
            var step: CGFloat = s * 0.045
            while y < size.height {
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
                y += step
                step *= 1.32
            }
            // Vertical lines fanning from the vanishing point
            let vx = size.width / 2
            for i in stride(from: -6, through: 6, by: 1) {
                let bottomX = vx + CGFloat(i) * size.width * 0.16
                grid.move(to: CGPoint(x: vx, y: horizon))
                grid.addLine(to: CGPoint(x: bottomX, y: size.height))
            }
            ctx.stroke(grid, with: .color(Color(red: 0.4, green: 0.95, blue: 1.0).opacity(0.35)),
                       lineWidth: max(0.5, s * 0.004))
        }
    }

    private func speedStreaks(_ s: CGFloat) -> some View {
        Canvas { ctx, size in
            for (i, frac) in [0.16, 0.27, 0.85].enumerated() {
                var p = Path()
                let y = size.height * frac
                p.move(to: CGPoint(x: size.width * 0.08, y: y))
                p.addLine(to: CGPoint(x: size.width * (0.42 + Double(i) * 0.06), y: y))
                let c: Color = i == 2 ? .orange : Color(red: 0.4, green: 0.95, blue: 1.0)
                ctx.stroke(p, with: .color(c.opacity(0.55)),
                           style: StrokeStyle(lineWidth: s * 0.012, lineCap: .round))
            }
        }
    }

    /// The central RJ45-style network port with two glowing link LEDs.
    private func port(_ s: CGFloat) -> some View {
        ZStack {
            // Port body
            RoundedRectangle(cornerRadius: s * 0.04, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.05)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: s * 0.46, height: s * 0.40)
                .overlay(
                    RoundedRectangle(cornerRadius: s * 0.04, style: .continuous)
                        .stroke(Color(red: 0.4, green: 0.95, blue: 1.0).opacity(0.9),
                                lineWidth: s * 0.012)
                        .shadow(color: Color(red: 0.4, green: 0.95, blue: 1.0).opacity(0.8),
                                radius: s * 0.03))

            // Gold contact pins
            HStack(spacing: s * 0.018) {
                ForEach(0..<6, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: s * 0.006)
                        .fill(LinearGradient(colors: [Color(red: 1, green: 0.86, blue: 0.5),
                                                      Color(red: 0.8, green: 0.6, blue: 0.2)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: s * 0.03, height: s * 0.11)
                }
            }
            .offset(y: -s * 0.06)

            // Link LEDs (green = link, amber = traffic) with bloom
            HStack(spacing: s * 0.22) {
                led(color: .green, s: s)
                led(color: .orange, s: s)
            }
            .offset(y: s * 0.10)
        }
        .shadow(color: .black.opacity(0.5), radius: s * 0.03, y: s * 0.01)
    }

    private func led(color: Color, s: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: s * 0.055, height: s * 0.055)
            .shadow(color: color.opacity(0.9), radius: s * 0.035)
            .shadow(color: color.opacity(0.6), radius: s * 0.07)
    }
}

// MARK: - Dock icon rasterization

enum AppIconRenderer {
    /// Renders the SwiftUI icon to an NSImage for `NSApp.applicationIconImage`.
    /// (No .app bundle is needed when running via `swift run`.)
    @MainActor
    static func dockIcon(size: CGFloat = 512) -> NSImage? {
        let renderer = ImageRenderer(content:
            AppIconView().frame(width: size, height: size))
        renderer.scale = 2
        return renderer.nsImage
    }
}

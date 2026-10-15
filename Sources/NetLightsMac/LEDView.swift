import SwiftUI

// MARK: - LED indicator

struct LEDView: View {
    enum LEDState {
        case off       // grey — no link
        case active    // green — link up, no traffic
        case traffic   // amber — traffic detected (pulses)
    }

    var state: LEDState

    /// Full pulse period, yellow → orange → yellow. 0.18 s each way, eased: the look the LED has
    /// always had.
    private static let pulsePeriod: TimeInterval = 0.36

    var body: some View {
        switch state {
        case .off:
            led(fill: Color(white: 0.4), glow: .clear, glowRadius: 0)
        case .active:
            led(fill: .green, glow: .green.opacity(0.5))
        case .traffic:
            // The pulse is computed from the clock on every update. No `.animation`, no
            // `withAnimation`: SwiftUI creates no animation objects for it at all, which is the
            // requirement here, not a nicety — see the note at the bottom of this file. The
            // timeline exists only while the LED is in the traffic state, so idle LEDs cost
            // nothing.
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                led(fill: .yellow, glow: .orange.opacity(0.6))
                    .overlay(Circle().fill(Color.orange).opacity(Self.pulse(at: context.date)))
            }
        }
    }

    private func led(fill: Color, glow: Color, glowRadius: CGFloat = 4) -> some View {
        Circle()
            .fill(fill)
            .frame(width: 9, height: 9)
            .shadow(color: glow, radius: glowRadius)
    }

    /// 0 → 1 → 0 across `pulsePeriod`, eased with smoothstep — the same shape as
    /// `.easeInOut` with `autoreverses`, but a plain function of time.
    private static func pulse(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: pulsePeriod) / pulsePeriod
        let tri = t < 0.5 ? t * 2 : (1 - t) * 2
        return tri * tri * (3 - 2 * tri)
    }
}

extension LEDView.LEDState {
    init(hasLink: Bool, hasTraffic: Bool) {
        if hasTraffic { self = .traffic }
        else if hasLink { self = .active }
        else { self = .off }
    }
}

// Why no SwiftUI animation here at all? Two attempts taught the same lesson.
//
// 1. Through 1.9.5 the LED used `withAnimation(.easeInOut(0.18).repeatForever(autoreverses:
//    true)) { blink = true }`, restarted from `onChange(of: state)` whenever an interface
//    re-entered `.traffic`. A repeatForever animation never reports completion, so SwiftUI never
//    drops it, and a non-animated reset does not cancel it — running animations are additive on
//    top of the new base value. The traffic flags clear 5 s after the last byte, so bursty
//    interfaces flip all day and every restart APPENDED one more infinite animation to the fill.
//    After five days the shipped 1.9.5 held 7,681 of them on one attribute and the main thread
//    spent 99 % of every frame evaluating and copying that list.
//
// 2. The first 1.9.6 attempt (2026-10-15) toggled the colour from a TimelineView with a FINITE
//    `.animation(.easeInOut(0.18), value:)` crossfade, on the theory that finite animations
//    complete and are released. They are — but only once the whole combined animation on the
//    attribute is finished, and SwiftUI keeps every member until then. Back-to-back crossfades
//    (a new one every 0.18 s) never leave such a gap while an LED blinks, so the soak build
//    reached 5,166 live animations in five minutes; they were freed only when the LED stopped.
//    An interface with sustained traffic would have grown without bound.
//
// Rule for this file: a continuously blinking indicator must not be driven by SwiftUI
// animations at all. Compute the pulse from the clock and set the value directly.
// Record: `.maintainer/2026-10-14-sluggish-after-5-days.md`.

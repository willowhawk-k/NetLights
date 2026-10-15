import SwiftUI

// MARK: - LED indicator

struct LEDView: View {
    enum LEDState {
        case off       // grey — no link
        case active    // green — link up, no traffic
        case traffic   // amber — traffic detected (blinks)
    }

    var state: LEDState

    /// Half of the blink period: how long each colour is shown, and the crossfade length.
    /// 0.18 s each way reproduces the 0.36 s eased pulse the LED has always had.
    private static let blinkHalfPeriod: TimeInterval = 0.18

    var body: some View {
        switch state {
        case .off:
            led(fill: Color(white: 0.4), glow: .clear, glowRadius: 0)
        case .active:
            led(fill: .green, glow: .green.opacity(0.5))
        case .traffic:
            // Blink from a clock, NOT from a `repeatForever` animation — see the note at the
            // bottom of this file. The timeline exists only while the LED is in the traffic
            // state, so idle LEDs cost nothing and nothing outlives the state that needs it.
            TimelineView(.periodic(from: .now, by: Self.blinkHalfPeriod)) { context in
                let phase = Int((context.date.timeIntervalSinceReferenceDate / Self.blinkHalfPeriod)
                    .rounded(.down))
                let lit = phase % 2 == 0
                led(fill: lit ? .orange : .yellow, glow: .orange.opacity(0.6))
                    // A FINITE crossfade. It completes before the next tick and SwiftUI releases
                    // it, so the attribute carries one or two running animations, never more.
                    .animation(.easeInOut(duration: Self.blinkHalfPeriod), value: lit)
            }
        }
    }

    private func led(fill: Color, glow: Color, glowRadius: CGFloat = 4) -> some View {
        Circle()
            .fill(fill)
            .frame(width: 9, height: 9)
            .shadow(color: glow, radius: glowRadius)
    }
}

extension LEDView.LEDState {
    init(hasLink: Bool, hasTraffic: Bool) {
        if hasTraffic { self = .traffic }
        else if hasLink { self = .active }
        else { self = .off }
    }
}

// Why not `withAnimation(.easeInOut(0.18).repeatForever(autoreverses: true)) { blink = true }`?
//
// That was the implementation through 1.9.5, restarted from `onChange(of: state)` whenever an
// interface entered `.traffic`, and it is the second cause of "the app gets sluggish after a
// day" (found 2026-10-14; `.maintainer/2026-10-14-sluggish-after-5-days.md`). A repeatForever
// animation never reports completion, so SwiftUI never drops it from the attribute's animator,
// and a non-animated reset of the state does not cancel it either — running animations are
// additive on top of the new base value. The traffic flags clear 5 s after the last byte, so
// any bursty interface flips in and out of `.traffic` all day, and every restart APPENDED one
// more infinite animation to this circle's fill colour. After five days the shipped 1.9.5 held
// 7,681 of them on one attribute and the main thread spent 99 % of every frame evaluating and
// copying that list. Rule: never start a `repeatForever` animation from a state change that can
// recur. Blink from a clock and animate with something that finishes.

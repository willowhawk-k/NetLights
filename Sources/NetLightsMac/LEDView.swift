import SwiftUI

// MARK: - LED indicator

struct LEDView: View {
    enum LEDState {
        case off       // grey — no link
        case active    // green — link up, no traffic
        case traffic   // amber — traffic detected (blinks)
    }

    var state: LEDState

    @State private var blink = false

    var color: Color {
        switch state {
        case .off:     return Color(white: 0.4)
        case .active:  return .green
        case .traffic: return blink ? .orange : .yellow
        }
    }

    var glowColor: Color {
        switch state {
        case .off:     return .clear
        case .active:  return .green.opacity(0.5)
        case .traffic: return .orange.opacity(0.6)
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .shadow(color: glowColor, radius: state == .off ? 0 : 4)
            .onChange(of: state) { newState in
                blink = false
                if newState == .traffic {
                    startBlink()
                }
            }
            .onAppear {
                if state == .traffic { startBlink() }
            }
    }

    private func startBlink() {
        withAnimation(.easeInOut(duration: 0.18).repeatForever(autoreverses: true)) {
            blink = true
        }
    }
}

extension LEDView.LEDState {
    init(hasLink: Bool, hasTraffic: Bool) {
        if hasTraffic { self = .traffic }
        else if hasLink { self = .active }
        else { self = .off }
    }
}

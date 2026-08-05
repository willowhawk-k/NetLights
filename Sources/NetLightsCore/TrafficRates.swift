import Foundation

/// Turns raw rx/tx byte counters into the smoothed per-second rates and the "is this link
/// busy" flags that the graph, the web UI and the TUI all draw.
///
/// This is lifted verbatim from the macOS GUI's `updateTrafficStates` — same EMA weight,
/// same dt window, same 5-second activity hold — so every surface reports the SAME number
/// for the same link. (Before this existed the Linux web UI derived its own rates in
/// JavaScript and disagreed with the app: it showed bytes/sec where the shared formatters
/// show bits/sec.)
///
/// Pure and Foundation-only: the caller supplies a monotonic `now`, which keeps Core free
/// of platform clock APIs (`clock_gettime_nsec_np` is Darwin-only) and makes the whole
/// thing unit-testable with a fake clock.
public struct TrafficRateDeriver {
    /// EMA weight: blends each sample with the previous rate so the on-wire number tracks
    /// real throughput without flickering between polls.
    private static let alpha = 0.5
    /// Only compute a rate over a sane window. Too short (an off-cadence manual refresh
    /// landing just after a timer tick) would project a sub-second burst to a per-second
    /// figure; too long (first sample after sleep/wake, or a stalled timer) would divide a
    /// large byte delta by a tiny dt and spike. Outside the window we skip the rate but
    /// still re-baseline, so the next normal tick recomputes clean.
    private static let minDT = 0.4
    private static let maxDT = 5.0
    /// Keeps a link lit during sustained traffic even when an interface reports its
    /// counters in bursts (iPhone USB NCM, tunnels), without blinking. Dims 5s after
    /// traffic stops.
    private static let activityHold = 5.0

    private var previous: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var states: [String: TrafficState] = [:]
    private var lastRxActivity: [String: Double] = [:]
    private var lastTxActivity: [String: Double] = [:]
    private var lastSample: Double = 0

    public init() {}

    /// Feed a fresh set of interfaces. `now` must be monotonic seconds.
    public mutating func update(_ interfaces: [InterfaceInfo],
                                now: Double = ProcessInfo.processInfo.systemUptime) {
        let dt = lastSample > 0 ? now - lastSample : 0
        lastSample = now

        for iface in interfaces {
            var state = states[iface.id] ?? TrafficState()

            if let prev = previous[iface.id] {
                if iface.rxBytes > prev.rx { lastRxActivity[iface.id] = now }
                if iface.txBytes > prev.tx { lastTxActivity[iface.id] = now }
                if dt > Self.minDT && dt < Self.maxDT {
                    // Guard against counter resets (interface re-added) and wraps.
                    let dRx = iface.rxBytes >= prev.rx ? Double(iface.rxBytes - prev.rx) : 0
                    let dTx = iface.txBytes >= prev.tx ? Double(iface.txBytes - prev.tx) : 0
                    state.rxRate = state.rxRate * (1 - Self.alpha) + (dRx / dt) * Self.alpha
                    state.txRate = state.txRate * (1 - Self.alpha) + (dTx / dt) * Self.alpha
                }
            }
            state.rxActive = now - (lastRxActivity[iface.id] ?? -.infinity) < Self.activityHold
            state.txActive = now - (lastTxActivity[iface.id] ?? -.infinity) < Self.activityHold
            state.lastRx = iface.rxBytes
            state.lastTx = iface.txBytes

            states[iface.id] = state
            previous[iface.id] = (iface.rxBytes, iface.txBytes)
        }
    }

    public func state(for interfaceID: String) -> TrafficState {
        states[interfaceID] ?? TrafficState()
    }

    /// The whole map, for renderers that take one (the SVG renderer feeds it to the layout
    /// engine, which needs per-interface activity to honour "Hide inactive").
    public var allStates: [String: TrafficState] { states }

    /// Smoothed receive rate in BYTES/sec — feed to `formatRate` for a bits/sec label.
    public func rxRate(for interfaceID: String) -> Double { states[interfaceID]?.rxRate ?? 0 }
    public func txRate(for interfaceID: String) -> Double { states[interfaceID]?.txRate ?? 0 }

    /// True when either direction moved within the activity hold — what lights a wire.
    public func isActive(_ interfaceID: String) -> Bool {
        guard let s = states[interfaceID] else { return false }
        return s.rxActive || s.txActive
    }
}

// C18: the ONLY link between server health and the optional Remote Tunnel.
//
// Ownership model: the backend owns its own lifecycle and never waits on,
// checks, or starts the tunnel. The tunnel optionally FOLLOWS backend health
// when the user enabled "start/stop tunnel with server". This file is the
// entire coupling, as a pure function — no Foundation, no process spawns, no
// main-actor state — so the decoupling is unit-testable in isolation.
//
// Decisions fire only on health *transitions* (healthy↔unhealthy), never on
// every poll tick: a steady state can't repeatedly retry a failed tunnel, and
// the very first poll after launch (previousHealthy == nil) may start an
// opted-in tunnel but never stops one it didn't see healthy first.

enum TunnelAutopilotAction: Equatable {
    case none
    case start
    case stop
}

enum TunnelAutopilot {
    static func decide(
        previousHealthy: Bool?,
        healthy: Bool,
        startWithServer: Bool,
        stopWithServer: Bool,
        tunnelUsable: Bool,      // cloudflared installed AND config found
        tunnelStopped: Bool,     // our state == .stopped (not failed/external)
        tunnelProcessAlive: Bool // we own a running cloudflared child
    ) -> TunnelAutopilotAction {
        guard tunnelUsable else { return .none }
        // Transition gate: no change in health → no action.
        if previousHealthy == healthy { return .none }
        if healthy {
            return (startWithServer && tunnelStopped) ? .start : .none
        }
        // Only stop on an observed healthy→unhealthy transition; an app-launch
        // first poll that finds the server down must not kill a tunnel.
        if previousHealthy == true {
            return (stopWithServer && tunnelProcessAlive) ? .stop : .none
        }
        return .none
    }
}

/// Bounded child-process restart cadence, independent of server polling.
/// A brief registration must not reset a crash loop's backoff.
struct TunnelRecovery {
    private(set) var enabled = false
    private var delay: Double = 2

    mutating func arm() { enabled = true; delay = 2 }
    mutating func cancel() { enabled = false; delay = 2 }
    mutating func didDisconnect(stableFor: Double) {
        if stableFor >= 60 { delay = 2 }
    }
    mutating func nextDelay() -> Double? {
        guard enabled else { return nil }
        let result = delay
        delay = min(delay * 2, 60)
        return result
    }
}

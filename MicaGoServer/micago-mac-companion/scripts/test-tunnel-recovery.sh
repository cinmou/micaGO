#!/bin/sh
# Exercise the production supervisor using harmless owned fixture processes.
set -eu
cd "$(dirname "$0")/.."
TASK_TMP=$(mktemp -d)
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation

@MainActor
final class Gate {
    var delays: [Double] = []
    var waiters: [CheckedContinuation<Void, Error>] = []
    func wait(_ delay: Double) async throws {
        delays.append(delay)
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }
    func release() {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

@main
struct Tests {
    @MainActor static func main() async {
        var failures = 0
        func check(_ value: Bool, _ name: String) {
            print("\(value ? "ok  " : "FAIL") \(name)")
            if !value { failures += 1 }
        }
        func settle(_ predicate: () -> Bool) async {
            for _ in 0..<200 {
                if predicate() { return }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        var policy = TunnelRecovery()
        check(policy.nextDelay() == nil, "recovery requires an owned start")
        policy.arm()
        check((0..<8).compactMap { _ in policy.nextDelay() } == [2,4,8,16,32,60,60,60], "exponential backoff is capped")
        policy.didDisconnect(stableFor: 59)
        check(policy.nextDelay() == 60, "brief registration does not reset crash loop")
        policy.didDisconnect(stableFor: 60)
        check(policy.nextDelay() == 2, "stable connection resets backoff")
        policy.cancel()
        check(policy.nextDelay() == nil, "cancel disarms retries")

        let suite = "micago-tunnel-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = Gate()
        var external = false
        var children: [Process] = []
        var fixture = "exit 0"
        let controller = TunnelController(defaults: defaults,
            configuration: ("/bin/sh", "fixture"),
            externalProbe: { external },
            makeProcess: { _, _ in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", fixture]
                children.append(p)
                return p
            }, sleep: { try await gate.wait($0) })
        controller.start()
        await settle { gate.delays.count == 1 }
        check(controller.retryDelay == 2 && children.count == 1, "unexpected clean exit schedules recovery")
        controller.serverHealthChanged(healthy: true)
        controller.serverHealthChanged(healthy: true)
        check(children.count == 1, "steady health polls do not bypass backoff")
        fixture = "exit 7"
        gate.release()
        await settle { gate.delays.count == 2 }
        check(controller.retryDelay == 4 && children.count == 2, "failed retry increases interval")
        controller.stop()
        gate.release()
        try? await Task.sleep(nanoseconds: 50_000_000)
        check(controller.state == .stopped && controller.retryDelay == nil && children.count == 2, "Stop cancels a sleeping restart")

        controller.start()
        await settle { gate.delays.count == 3 }
        check(controller.retryDelay == 2, "manual start resets backoff")
        controller.startWithServer = true
        controller.startWithServer = false
        gate.release()
        try? await Task.sleep(nanoseconds: 50_000_000)
        check(children.count == 3 && controller.retryDelay == nil, "auto-start opt-out cancels pending recovery")

        controller.start()
        await settle { gate.delays.count == 4 }
        controller.stopWithServer = true
        controller.serverHealthChanged(healthy: false)
        gate.release()
        try? await Task.sleep(nanoseconds: 50_000_000)
        check(controller.state == .stopped && children.count == 4, "server stop cancels recovery without a live child")
        controller.stopWithServer = false
        controller.start()
        await settle { gate.delays.count == 5 }
        controller.serverHealthChanged(healthy: false)
        check(controller.retryDelay != nil, "without stop opt-in backend downtime leaves recovery alone")
        external = true
        gate.release()
        await settle { controller.state == .runningExternally }
        check(children.count == 5 && controller.retryDelay == nil, "external tunnel appearing during backoff prevents takeover")
        controller.stop()
        check(controller.state == .runningExternally, "Stop does not change external ownership")
        external = false

        fixture = "printf 'Registered tunnel connection\\n'; exec /bin/sleep 30"
        controller.start()
        await settle { controller.state == .running }
        check(controller.state == .running && children.count == 6, "real registration marks owned child running")
        controller.restart()
        await settle { children.count == 7 && controller.state == .running }
        check(!children[5].isRunning && children.count == 7 && children[6].isRunning, "Restart waits for old child to exit")
        children[6].terminate()
        await settle { gate.delays.count == 6 }
        controller.shutdownForQuit()
        gate.release()
        controller.start()
        controller.restart()
        try? await Task.sleep(nanoseconds: 50_000_000)
        check(children.count == 7 && controller.retryDelay == nil, "quit cancels recovery and rejects later start")
        check(children.allSatisfy { !$0.isRunning }, "no fixture child survives")

        let raceGate = Gate()
        var raceChildren: [Process] = []
        var raceFixture = "exit 1"
        let races = TunnelController(defaults: defaults,
            configuration: ("/bin/sh", "fixture"), externalProbe: { false },
            makeProcess: { _, _ in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", raceFixture]
                raceChildren.append(p)
                return p
            }, sleep: { try await raceGate.wait($0) })
        races.start()
        await settle { raceGate.delays.count == 1 }
        races.stop()
        races.start()
        await settle { raceGate.delays.count == 2 }
        raceFixture = "printf 'Registered tunnel '; /bin/sleep 0.05; printf 'connection\\n'; exec /bin/sleep 30"
        raceGate.release() // wakes both the cancelled and current sleeper
        await settle { races.state == .running }
        check(raceChildren.count == 3 && races.state == .running, "stale sleeper cannot launch twice; split log registration works")
        races.stopWithServer = true
        races.serverHealthChanged(healthy: false)
        check(raceChildren[2].isRunning, "initial unhealthy poll does not kill a manually owned tunnel")
        races.restart()
        races.stop()
        await settle { races.state == .stopped }
        check(raceChildren.count == 3 && !raceChildren[2].isRunning, "Stop cancels a queued manual Restart")
        races.start()
        await settle { races.state == .running }
        races.restart()
        races.shutdownForQuit()
        await settle { races.state == .stopped }
        check(raceChildren.count == 4 && raceChildren.allSatisfy { !$0.isRunning }, "quit cancels queued Restart and terminates only owned child")

        // Launch errors use the same cadence, without touching real config.
        let launchGate = Gate()
        let bad = TunnelController(defaults: defaults,
            configuration: ("/nonexistent-micago-fixture", "fixture"),
            externalProbe: { false }, sleep: { try await launchGate.wait($0) })
        bad.start()
        await settle { launchGate.delays.count == 1 }
        check(bad.retryDelay == 2, "process launch failure enters backoff")
        bad.shutdownForQuit()
        launchGate.release()
        exit(failures == 0 ? 0 : 1)
    }
}
SWIFT
xcrun swiftc -parse-as-library -o "$TASK_TMP/recovery-test" \
    MicaGoCompanion/Services/TunnelAutopilot.swift \
    MicaGoCompanion/Services/TunnelController.swift "$TASK_TMP/main.swift"
"$TASK_TMP/recovery-test"

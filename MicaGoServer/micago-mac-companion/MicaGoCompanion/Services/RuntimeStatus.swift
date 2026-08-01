import Foundation
import AppKit
import IOKit.pwr_mgt

/// Local checks/actions for Messages.app. The companion runs on the same Mac as
/// the server, so it can check this directly via NSWorkspace — no server round
/// trip and no Automation permission required.
enum MessagesApp {
    static let bundleID = "com.apple.MobileSMS"

    static func isRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    static func open() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Holds macOS power assertions for the duration of Keep Awake.
///
/// Replaces the old `caffeinate` child process (C74). Spawning a helper was
/// unreliable in a hardened-runtime app and left the toggle stuck "on" when the
/// child died, and `caffeinate -s` only prevents system sleep on AC power — so
/// on battery the Mac slept anyway and the relay dropped. This is the
/// KeepingYouAwake (MIT) approach: in-process `IOPMAssertionCreateWithName`
/// assertions, released deterministically.
///
/// Two assertions are held together:
///   * PreventUserIdleSystemSleep — the Mac does not idle-sleep, so the relay
///     keeps serving. The display may still sleep (wanted for a bridge).
///   * NetworkClientActive — keeps the network stack serving remote clients
///     while the display is off.
private final class PowerAssertions {
    private var ids: [IOPMAssertionID] = []

    var isActive: Bool { !ids.isEmpty }

    /// Takes the assertions. Returns false (and holds none) when macOS refuses.
    func acquire(reason: String) -> Bool {
        guard ids.isEmpty else { return true }
        let types = [
            kIOPMAssertionTypePreventUserIdleSystemSleep,
            kIOPMAssertNetworkClientActive,
        ]
        var acquired: [IOPMAssertionID] = []
        for type in types {
            var id: IOPMAssertionID = IOPMAssertionID(0)
            let status = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &id
            )
            if status == kIOReturnSuccess {
                acquired.append(id)
            }
        }
        // All-or-nothing: a partial hold would report "on" while still sleeping.
        guard !acquired.isEmpty else { return false }
        ids = acquired
        return true
    }

    func release() {
        for id in ids { IOPMAssertionRelease(id) }
        ids.removeAll()
    }

    deinit {
        for id in ids { IOPMAssertionRelease(id) }
    }
}

/// RuntimeMonitor is a single shared source of macOS-local runtime state
/// (Messages.app running, Keep-Awake) so multiple companion surfaces (Dashboard,
/// Permissions) reflect the same values. Keep-awake lives in the companion,
/// never in the Go relay core.
@MainActor
final class RuntimeMonitor: ObservableObject {
    static let shared = RuntimeMonitor()

    @Published private(set) var messagesRunning: Bool = MessagesApp.isRunning()
    @Published private(set) var keepAwakeActive: Bool = false

    private let powerAssertions = PowerAssertions()
    private var pollTask: Task<Void, Never>?

    func startMonitoring() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.messagesRunning = MessagesApp.isRunning()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshMessages() {
        messagesRunning = MessagesApp.isRunning()
    }

    func openMessages() {
        MessagesApp.open()
    }

    /// Toggles Keep Awake. The published flag mirrors the assertions actually
    /// held, so a refusal by macOS shows as "off" instead of a lying switch.
    func setKeepAwake(_ on: Bool) {
        if on {
            let ok = powerAssertions.acquire(reason: "micaGO is relaying messages")
            keepAwakeActive = ok
        } else {
            powerAssertions.release()
            keepAwakeActive = false
        }
    }

    /// Releases the assertions on quit — power assertions are process-scoped, but
    /// dropping them explicitly keeps `pmset -g assertions` clean during restarts.
    func releaseKeepAwake() {
        powerAssertions.release()
        keepAwakeActive = false
    }
}

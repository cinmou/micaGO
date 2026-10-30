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

/// In-process Keep Awake assertions; accepted assertions are released on stop or quit.
private final class PowerAssertions {
    private var ids: [IOPMAssertionID] = []

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
        // Retain the assertions accepted by macOS.
        guard !acquired.isEmpty else { return false }
        ids = acquired
        return true
    }

    func release() {
        for id in ids { IOPMAssertionRelease(id) }
        ids.removeAll()
    }

    deinit { release() }
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

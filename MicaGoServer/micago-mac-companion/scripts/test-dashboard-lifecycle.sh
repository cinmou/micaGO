#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 - <<'PY'
from pathlib import Path
import platform, plistlib, subprocess, tempfile, uuid

# This integration harness uses real SwiftUI/AppKit windows and requires a Mac
# desktop session. It replaces backend/contacts/update services with inert stubs.
major = int(subprocess.check_output(['sw_vers', '-productVersion'], text=True).split('.')[0])
if major < 15:
    raise SystemExit('SKIP dashboard lifecycle fixture requires macOS 15 scene suppression')
repo = Path.cwd()
app_source = (repo/'MicaGoCompanion/MicaGoCompanionApp.swift').read_text()
app_scene = app_source[:app_source.index('/// AppKit owns the menu-bar item')]
window_helpers = app_source[app_source.index("/// Only the scene's dashboard counts here."):]
close_observer = app_source[app_source.index('        NotificationCenter.default.addObserver(', app_source.index('// Re-evaluate the policy')):app_source.index('        // Bootstrap regardless')]
tracking = 'dashboardWindowTrackingBridge' if 'dashboardWindowTrackingBridge' in app_source else 'dashboardWindowOpeningBridge'
stubs = r'''
enum SidebarItem { case about, advanced }
@MainActor final class NavState { static let shared = NavState(); var selection: SidebarItem? }
enum L10n {
    static let languageKey = "appLanguage"
    static func languageIdentifier(for value: String) -> String { "en" }
    static func tr(_ value: String) -> String { value }
}
@MainActor final class FixtureServices: ObservableObject {
    static let shared = FixtureServices()
    @Published var authValid = false
    @Published var contactRevision = 0
    var loaded = false
    var serverEntries: [Int] = []
    var canCheckForUpdates = false
    func loadIfAuthorized() async {}
    func syncContactCache(_ values: [Int]) async {}
    func checkForUpdates() {}
}
typealias AppModel = FixtureServices
typealias RuntimeMonitor = FixtureServices
typealias BackendController = FixtureServices
typealias ContactsStore = FixtureServices
typealias TunnelController = FixtureServices
typealias SparkleUpdater = FixtureServices
struct ContentView: View {
    var body: some View {
        Text("Dashboard lifecycle fixture").frame(width: 820, height: 560).TRACKING()
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) {
        setbuf(stdout, nil)
        UserDefaults.standard.set(true, forKey: "hideDockIcon")
        CLOSE_OBSERVER
        DispatchQueue.main.async {
            for window in NSApp.windows where window.styleMask.contains(.titled) { window.orderOut(nil) }
            applyActivationPolicy()
        }
        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(400))
                let initial = existingDashboardWindow()
                if COLD {
                    precondition(initial == nil, "cold fixture must start without dashboard content")
                } else {
                    precondition(initial != nil && !hasVisibleDashboardWindow(), "hidden fixture retains a hidden dashboard")
                }
                presentDashboardFromAppKit()
                try await waitForDashboard()
                let opened = existingDashboardWindow()!
                if let initial { precondition(opened === initial, "hidden dashboard must be reused") }
                presentDashboardFromAppKit()
                presentDashboardFromAppKit()
                try await Task.sleep(for: .milliseconds(100))
                precondition(existingDashboardWindow() === opened, "repeated opens must reuse the same dashboard")
                opened.miniaturize(nil)
                presentDashboardFromAppKit()
                try await waitForDashboard()
                precondition(!opened.isMiniaturized, "menu opens must restore a minimized dashboard")
                // Finish the native minimize/restore animation before closing.
                try await Task.sleep(for: .milliseconds(600))
                opened.close()
                try await Task.sleep(for: .milliseconds(100))
                precondition(existingDashboardWindow() == nil, "closed dashboard references must be cleared")
                // An unrelated window must not be used as a dashboard fallback.
                let unrelated = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100),
                    styleMask: [.titled], backing: .buffered, defer: false)
                unrelated.isReleasedWhenClosed = false
                presentDashboardFromAppKit()
                try await waitForDashboard()
                precondition(existingDashboardWindow() !== unrelated)
                precondition(NSApp.windows.filter { $0.styleMask.contains(.titled) && $0 !== unrelated && ($0.isVisible || $0.isMiniaturized) }.count == 1,
                    "reopen must leave exactly one dashboard window")
                print("PASS MODE: initial open, hidden reuse, repeated opens, minimize, close/reopen, unrelated window")
                UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
                exit(0)
            } catch {
                print("FAIL MODE: \(error)")
                UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
                exit(1)
            }
        }
    }
    @MainActor func waitForDashboard() async throws {
        for _ in 0..<100 {
            if let window = existingDashboardWindow(), window.isVisible && window.isKeyWindow && NSApp.isActive { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        print("WAIT FAILED tracked=\(existingDashboardWindow() != nil) active=\(NSApp.isActive) windows=\(NSApp.windows.filter { $0.styleMask.contains(.titled) }.map { "id=\($0.windowNumber) visible=\($0.isVisible) key=\($0.isKeyWindow) tracked=\($0 === existingDashboardWindow()) title=\($0.title)" })")
        throw NSError(domain: "DashboardLifecycle", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "dashboard did not become visible, key and active"])
    }
}
'''.replace('TRACKING', tracking).replace('CLOSE_OBSERVER', close_observer)

for cold in (True, False):
    mode = 'cold-no-window' if cold else 'hidden-existing-window'
    scene = app_scene.replace('        .defaultSize(width: 1000, height: 720)',
        '        .defaultLaunchBehavior(.suppressed)\n        .defaultSize(width: 1000, height: 720)') if cold else app_scene
    with tempfile.TemporaryDirectory(prefix='micago-dashboard-lifecycle-') as temp:
        folder = Path(temp)
        bundle = folder/'DashboardFixture.app'
        contents = bundle/'Contents'
        executable = contents/'MacOS/DashboardFixture'
        executable.parent.mkdir(parents=True)
        (contents/'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'com.micago.dashboard-fixture.'+mode+'.'+uuid.uuid4().hex,
            'CFBundleExecutable': 'DashboardFixture', 'CFBundleName': 'DashboardFixture',
            'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'NSPrincipalClass': 'NSApplication',
        }))
        source = folder/'fixture.swift'
        source.write_text(scene+'\n'+window_helpers+'\n'+stubs.replace('COLD', str(cold).lower()).replace('MODE', mode))
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-target', platform.machine()+'-apple-macos15.0',
            str(repo/'MicaGoCompanion/Services/DashboardWindowOpener.swift'), str(source), '-o', str(executable)], check=True)
        stdout, stderr = folder/'stdout.log', folder/'stderr.log'
        result = subprocess.run(['/usr/bin/open', '-W', '-n', '-F',
            '--stdout', str(stdout), '--stderr', str(stderr), str(bundle)],
            text=True, capture_output=True, timeout=25)
        output = stdout.read_text() if stdout.exists() else ''
        errors = stderr.read_text() if stderr.exists() else ''
        print(output, end='')
        if result.returncode or 'PASS '+mode+':' not in output:
            print(errors[-2500:])
            print(result.stderr)
            raise SystemExit(result.returncode or 1)
PY

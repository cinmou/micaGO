import SwiftUI
import AppKit
import Combine

@main
struct MicaGoCompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Shared singletons so bootstrap/shutdown work even with no window open
    // (silent launch / menu-bar-only mode) and the AppDelegate can reach them.
    @StateObject private var model = AppModel.shared
    @StateObject private var runtime = RuntimeMonitor.shared
    @StateObject private var backend = BackendController.shared
    @StateObject private var contacts = ContactsStore()
    @StateObject private var tunnel = TunnelController.shared

    var body: some Scene {
        WindowGroup(id: "dashboard") {
            ContentView()
                .environmentObject(model)
                .environmentObject(runtime)
                .environmentObject(backend)
                .environmentObject(contacts)
                .environmentObject(tunnel)
                .task {
                    await contacts.loadIfAuthorized()
                    if contacts.loaded {
                        await model.syncContactCache(contacts.serverEntries)
                    }
                }
                .onReceive(contacts.$contactRevision) { _ in
                    guard contacts.loaded else { return }
                    Task { await model.syncContactCache(contacts.serverEntries) }
                }
                .onReceive(model.$authValid) { valid in
                    guard valid, contacts.loaded else { return }
                    Task { await model.syncContactCache(contacts.serverEntries) }
                }
        }
        .defaultSize(width: 1000, height: 720)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

    }
}

/// AppKit owns the menu-bar item because SwiftUI `MenuBarExtra` does not
/// reliably apply label modifiers to the actual NSStatusBarButton.
@MainActor
final class MenuBarStatusItemController: NSObject, NSMenuDelegate {
    private struct Appearance {
        var assetName: String
        var appearsDisabled: Bool
        var helpText: String
    }

    private let model: AppModel
    private let runtime: RuntimeMonitor
    private let backend: BackendController
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel, runtime: RuntimeMonitor, backend: BackendController) {
        self.model = model
        self.runtime = runtime
        self.backend = backend
        super.init()

        menu.autoenablesItems = false
        menu.delegate = self

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
        }
        statusItem.menu = menu
        updateStatusItem()

        backend.$processState
            .combineLatest(model.$reachable)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateStatusItem() }
            .store(in: &cancellables)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private var displayState: ServerDisplayState {
        serverDisplayState(process: backend.processState, reachable: model.reachable)
    }

    private var appearance: Appearance {
        switch displayState {
        case .running:
            return Appearance(
                assetName: "mica",
                appearsDisabled: false,
                helpText: L10n.tr("menu.running")
            )
        case .externalUnmanaged:
            return Appearance(
                assetName: "mica",
                appearsDisabled: false,
                helpText: L10n.tr("menu.external")
            )
        case .stopped, .starting, .stopping:
            return Appearance(
                assetName: "mica",
                appearsDisabled: true,
                helpText: L10n.tr("menu.notRunning")
            )
        case .notInstalled, .startingUnreachable, .crashed:
            return Appearance(
                assetName: "mica.error",
                appearsDisabled: false,
                helpText: L10n.tr("menu.notRunning")
            )
        }
    }

    /// Menu-bar icons should render at ~18×18 pt so they match system items.
    /// The SVG assets are 64×64; without an explicit size the button may blow
    /// them up to the raw pixel dimensions.
    private let menuBarIconSize = NSSize(width: 18, height: 18)

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let current = appearance
        let image = NSImage(named: current.assetName)
        image?.isTemplate = true
        image?.size = menuBarIconSize
        button.image = image
        button.appearsDisabled = current.appearsDisabled
        button.toolTip = current.helpText
    }

    private func rebuildMenu(_ menu: NSMenu) {
        let state = displayState
        menu.removeAllItems()

        let title = NSMenuItem(title: "micaGO — \(state.label)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        menu.addItem(item(L10n.tr("menu.openDashboard"), action: #selector(openDashboard)))

        let start = item(L10n.tr("menu.startServer"), action: #selector(startServer))
        start.isEnabled = canStart(state)
        menu.addItem(start)

        let stop = item(L10n.tr("menu.stopServer"), action: #selector(stopServer))
        stop.isEnabled = canStop
        menu.addItem(stop)

        let keepAwake = item(L10n.tr("menu.keepAwake"), action: #selector(toggleKeepAwake))
        keepAwake.state = runtime.keepAwakeActive ? .on : .off
        menu.addItem(keepAwake)

        menu.addItem(.separator())
        menu.addItem(item(L10n.tr("menu.quit"), action: #selector(quit)))
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func canStart(_ state: ServerDisplayState) -> Bool {
        guard backend.binaryExists else { return false }
        if state == .externalUnmanaged { return false }
        switch backend.processState {
        case .stopped, .exited, .failed, .notInstalled: return true
        default: return false
        }
    }

    private var canStop: Bool {
        switch backend.processState {
        case .running, .starting: return true
        default: return false
        }
    }

    @objc private func openDashboard() {
        presentDashboardFromAppKit()
    }

    @objc private func startServer() {
        backend.start()
    }

    @objc private func stopServer() {
        backend.stop()
    }

    @objc private func toggleKeepAwake() {
        runtime.setKeepAwake(!runtime.keepAwakeActive)
    }

    @objc private func quit() {
        backend.shutdownForQuitIfNeeded()
        NSApp.terminate(nil)
    }
}

/// AppDelegate owns app-lifetime bootstrap (so polling/auto-start run even when
/// launched silently with no window) and clean shutdown of the child backend.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var cancellables = Set<AnyCancellable>()
    private var menuBarStatusItem: MenuBarStatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarStatusItem = MenuBarStatusItemController(
            model: AppModel.shared,
            runtime: RuntimeMonitor.shared,
            backend: BackendController.shared
        )

        let hidden = UserDefaults.standard.bool(forKey: "launchHidden")
        if hidden {
            // Silent launch: close the window opened by the WindowGroup.
            DispatchQueue.main.async {
                for window in NSApp.windows where window.styleMask.contains(.titled) {
                    window.close()
                }
                applyActivationPolicy()
            }
        }

        // Apply the Dock-icon policy now (and again whenever a window opens/closes).
        applyActivationPolicy()

        // Re-evaluate the policy whenever a window closes so the app can drop
        // back to menu-bar-only (accessory) once the Dashboard is dismissed.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { _ in
            // willClose fires before the window leaves the list; re-evaluate next tick.
            DispatchQueue.main.async { applyActivationPolicy() }
        }

        // Bootstrap regardless of whether a window is shown.
        Task { @MainActor in
            AppModel.shared.reloadConfig()
            installTunnelFollower()
            await AppModel.shared.refresh()
            BackendController.shared.autoStartIfNeeded(externalReachable: AppModel.shared.reachable)
            AppModel.shared.refreshAfterBackendStart()
            AppModel.shared.startPolling()
            RuntimeMonitor.shared.startMonitoring()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        BackendController.shared.shutdownForQuitIfNeeded()
        TunnelController.shared.shutdownForQuit()
        RuntimeMonitor.shared.releaseKeepAwake()
    }

    // Keep the app (and menu bar) alive when the Dashboard window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSApp.activate(ignoringOtherApps: true) }
        return true
    }

    @MainActor
    private func installTunnelFollower() {
        guard cancellables.isEmpty else { return }
        AppModel.shared.$reachable
            .removeDuplicates()
            .sink { healthy in
                Task { @MainActor in
                    TunnelController.shared.serverHealthChanged(healthy: healthy)
                }
            }
            .store(in: &cancellables)
        BackendController.shared.$processState
            .removeDuplicates()
            .sink { state in
                guard case .running = state else { return }
                Task { @MainActor in
                    AppModel.shared.refreshAfterBackendStart()
                }
            }
            .store(in: &cancellables)
    }
}

extension BackendController {
    static let shared = BackendController()
}

/// Whether a main Dashboard window (titled, visible) is currently on screen.
/// The MenuBarExtra's status window is an untitled panel and is excluded.
func hasVisibleDashboardWindow() -> Bool {
    NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
}

private func existingDashboardWindow() -> NSWindow? {
    NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) }
}

/// Bridges SwiftUI's `openWindow` action to AppKit. The `WindowGroup` window has
/// the correct native toolbar/titlebar (large inline title, trailing controls);
/// a hand-rolled `NSWindow` does not. ContentView stores its `openWindow` action
/// here on appear so the AppKit menu-bar item can reopen the SAME WindowGroup
/// window instead of building a divergent one.
@MainActor
final class DashboardWindowOpener {
    static let shared = DashboardWindowOpener()
    var open: (() -> Void)?
}

@MainActor
private final class DashboardWindowPresenter {
    static let shared = DashboardWindowPresenter()
    private var window: NSWindow?

    func show() {
        if let existing = existingDashboardWindow() ?? window {
            existing.deminiaturize(nil)
            existing.makeKeyAndOrderFront(nil)
            applyActivationPolicy()
            return
        }

        let root = ContentView()
            .environmentObject(AppModel.shared)
            .environmentObject(RuntimeMonitor.shared)
            .environmentObject(BackendController.shared)
            .environmentObject(ContactsStore())
            .environmentObject(TunnelController.shared)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "micaGO"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.setFrameAutosaveName("MicaGoDashboard")
        window.makeKeyAndOrderFront(nil)
        self.window = window
        applyActivationPolicy()
    }
}

/// Single source of truth for the app's Dock presence. Accessory (no Dock icon)
/// only when the user enabled "Hide Dock icon" AND no Dashboard window is open;
/// otherwise regular. The menu-bar item is unaffected by activation policy.
func applyActivationPolicy() {
    let hideDock = UserDefaults.standard.bool(forKey: "hideDockIcon")
    let target: NSApplication.ActivationPolicy = (hideDock && !hasVisibleDashboardWindow()) ? .accessory : .regular
    if NSApp.activationPolicy() != target {
        NSApp.setActivationPolicy(target)
    }
}

/// Brings the app to the foreground and opens the dashboard window. Used by the
/// menu-bar "Open Dashboard" action and after a silent launch. Always restores
/// the regular activation policy first so the window can take focus.
@MainActor
func presentDashboard(openWindow: OpenWindowAction) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    openWindow(id: "dashboard")
}

@MainActor
func presentDashboardFromAppKit() {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)

    // Reuse the real WindowGroup window so the menu-bar path looks identical to
    // launching from the Dock (native toolbar/titlebar). Prefer an already-open
    // window; otherwise reopen the WindowGroup via the captured SwiftUI action.
    // The hand-rolled NSWindow is only a last resort (e.g. launched hidden and
    // never once shown, so no openWindow action was captured yet).
    if let existing = existingDashboardWindow() {
        existing.deminiaturize(nil)
        existing.makeKeyAndOrderFront(nil)
        applyActivationPolicy()
        return
    }
    if let open = DashboardWindowOpener.shared.open {
        open()
        applyActivationPolicy()
        return
    }
    DashboardWindowPresenter.shared.show()
}

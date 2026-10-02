import SwiftUI
import AppKit

// MARK: - Sidebar

enum SidebarItem: String, CaseIterable, Identifiable {
    // C23 cleanup: Debug + Log are technical tools, so they sit at the bottom
    // (below Advanced) instead of in the middle of the main workflow. Debug
    // holds debugging tools (Message Inspector); Log holds the server log only.
    case dashboard, connections, syncControl, notifications, tutorials, about, advanced, debug, log

    var id: String { rawValue }

    /// Primary navigation, shown in the main sidebar list.
    static let primary: [SidebarItem] = [
        .dashboard, .connections, .syncControl, .notifications, .tutorials, .about,
    ]
    /// Settings + tools, pinned to the bottom of the sidebar (native pattern).
    static func bottom(developerModeEnabled: Bool) -> [SidebarItem] {
        developerModeEnabled ? [.advanced, .debug, .log] : [.advanced]
    }

    var title: String {
        switch self {
        case .dashboard: return L10n.tr("sidebar.dashboard")
        case .connections: return L10n.tr("sidebar.connections")
        case .syncControl: return L10n.tr("sidebar.syncControl")
        case .debug: return L10n.tr("sidebar.debug")
        case .log: return L10n.tr("sidebar.log")
        case .notifications: return L10n.tr("sidebar.notifications")
        case .tutorials: return L10n.tr("sidebar.tutorials")
        case .about: return L10n.tr("sidebar.about")
        case .advanced: return L10n.tr("sidebar.advanced")
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.bottom.50percent"
        case .connections: return "network"
        case .syncControl: return "arrow.triangle.2.circlepath"
        case .debug: return "ladybug"
        case .log: return "doc.plaintext"
        case .notifications: return "bell"
        case .tutorials: return "book"
        case .about: return "info.circle"
        case .advanced: return "gearshape"
        }
    }
}

// MARK: - Shell

/// Shared sidebar selection so deep views can switch tabs.
@MainActor final class NavState: ObservableObject {
    static let shared = NavState()
    @Published var selection: SidebarItem? = .dashboard
}

struct ContentView: View {
    @AppStorage(L10n.languageKey) private var appLanguage = "system"
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var runtime: RuntimeMonitor
    @EnvironmentObject var backend: BackendController
    @StateObject private var nav = NavState.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            // Native macOS sidebar: primary items in the scrolling list, with
            // Settings + tools pinned at the bottom. Both lists are sidebar-styled
            // and share the same selection, so exactly one row is ever highlighted.
            List(selection: $nav.selection) {
                ForEach(SidebarItem.primary) { item in
                    Label(item.title, systemImage: item.symbol).tag(item)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("micaGO")
            .frame(minWidth: 215)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                let bottomItems = SidebarItem.bottom(developerModeEnabled: model.developerModeEnabled)
                VStack(spacing: 0) {
                    Divider()
                    Spacer().frame(height: 6)
                    List(selection: $nav.selection) {
                        ForEach(bottomItems) { item in
                            Label(item.title, systemImage: item.symbol).tag(item)
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
                    .frame(height: 38 * CGFloat(bottomItems.count))
                }
            }
        } detail: {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        detailContent.id(appLanguage)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle(nav.selection?.title ?? "micaGO")
                // Server status + primary control live in the native window
                // toolbar (trailing). Two separate ToolbarItems so macOS 26
                // gives each its own Liquid-Glass treatment instead of fusing
                // them into one oversized capsule.
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { ServerStatusToolbarPill().id(appLanguage) }
                    ToolbarItem(placement: .primaryAction) { ServerPrimaryToolbarButton().id(appLanguage) }
                }
            }
        }
        .environmentObject(nav)
        .environment(\.locale, Locale(identifier: L10n.languageIdentifier(for: appLanguage)))
        .frame(minWidth: 820, idealWidth: 1000, minHeight: 560, idealHeight: 720)
        // Expose the WindowGroup's openWindow to AppKit so the menu-bar "Open
        // Dashboard" reopens THIS window (native toolbar/titlebar) rather than a
        // hand-rolled NSWindow that renders the toolbar differently.
        .onAppear {
            DashboardWindowOpener.shared.open = { openWindow(id: "dashboard") }
        }
        .onChange(of: model.developerModeEnabled) { enabled in
            if !enabled, nav.selection == .debug || nav.selection == .log {
                nav.selection = .advanced
            }
        }
        // Bootstrap (config/poll/auto-start/runtime) is owned by the AppDelegate
        // so it runs even when launched silently with no window. Polling stays
        // alive for the menu-bar surface; it is not torn down when the window
        // closes.
    }

    @ViewBuilder private var detailContent: some View {
        switch nav.selection ?? .dashboard {
        case .dashboard: DashboardPage()
        case .connections: ConnectionsPage()
        case .syncControl: SyncControlPage()
        case .debug:
            // C23: debugging tools only — server logs live on the Log page.
            MessageInspectorPage()
        case .log: LogsPage()
        case .notifications: NotificationsPage()
        case .tutorials: TutorialsPage()
        case .about: AboutPage()
        case .advanced: AdvancedPage()
        }
    }
}

// MARK: - Shared display helpers

@MainActor
private func displayState(_ backend: BackendController, _ model: AppModel) -> ServerDisplayState {
    serverDisplayState(process: backend.processState, reachable: model.reachable)
}

private func openFullDiskAccessSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
        NSWorkspace.shared.open(url)
    }
}

/// Shown when the backend failed due to Full Disk Access, or the running server
/// reports FDA denied. Clear remediation instead of raw "operation not permitted".
private struct FullDiskAccessBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.badge.exclamationmark").foregroundStyle(.red)
                Text("Full Disk Access required").fontWeight(.semibold)
            }
            Text("micaGO can't read the Messages database. Give micaGO Companion Full Disk Access, then start the server again.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Full Disk Access Settings") { openFullDiskAccessSettings() }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.red.opacity(0.4), lineWidth: 1))
    }
}

@MainActor
private func fdaNeeded(_ backend: BackendController, _ model: AppModel) -> Bool {
    if backend.failureKind == .fullDiskAccess { return true }
    if model.status?.permissions.fullDiskAccess.status == "denied" { return true }
    return false
}

// MARK: - Toolbar server status + control

/// Compact server-status indicator for the window toolbar: a status dot (or
/// warning icon when crashed) plus a short label. Plain content only — it draws
/// **no** background of its own, so it sits cleanly inside the single system
/// toolbar (Liquid-Glass) group alongside the control button.
private struct ServerStatusToolbarPill: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var backend: BackendController

    var body: some View {
        let state = displayState(backend, model)
        HStack(spacing: 8) {
            if state == .crashed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
            } else {
                Circle()
                    .fill(state.isHealthyDot ? Color.green : Color.secondary)
                    .frame(width: 9, height: 9)
            }
            Text(state.compactLabel)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(minHeight: 24)
        .help(state.label)
    }
}

/// Primary server control for the toolbar. Renders as a native `Button` so it
/// picks up the system toolbar (Liquid-Glass) styling automatically. While
/// starting/stopping it shows a progress indicator instead of a button.
private struct ServerPrimaryToolbarButton: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var backend: BackendController

    var body: some View {
        // Uniform breathing room around the control (kept toolbar-sized). The
        // trailing pad gives the whole glass group its right-hand margin; the
        // leading pad separates the control from the status label.
        control
            .padding(.leading, 6)
            .padding(.trailing, 12)
    }

    @ViewBuilder private var control: some View {
        let state = displayState(backend, model)

        switch backend.processState {
        case .starting, .stopping:
            ProgressView()
                .controlSize(.small)
                .help(backend.processState == .stopping ? L10n.localized( "Stopping server…") : L10n.localized( "Starting server…"))
        case .running:
            Button { backend.stop() } label: {
                Label("Stop server", systemImage: "stop.fill")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .help("Stop server")
        default:
            // stopped / crashed / exited / notInstalled, or an external server.
            let canStart = backend.binaryExists && state != .externalUnmanaged
            Button { backend.start() } label: {
                Label("Start server", systemImage: "play.fill")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .disabled(!canStart)
            .help(startHelp(state))
        }
    }

    private func startHelp(_ state: ServerDisplayState) -> String {
        if state == .externalUnmanaged {
            return L10n.localized( "An external server is running, so Companion can't control it")
        }
        if !backend.binaryExists { return L10n.localized( "No backend binary installed") }
        return L10n.localized( "Start server")
    }
}

// MARK: - Dashboard

private struct DashboardPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var backend: BackendController

    var body: some View {
        if fdaNeeded(backend, model) {
            FullDiskAccessBanner()
        }

        // 1. Status — Server (LAN, primary) + Remote (public/tunnel, optional).
        ServerRemoteCard()

        // 2. Live sync health/activity — concise technical status.
        LiveSyncMonitorCard()

        // 3. The single canonical place to set up a client.
        CreateConnectionCard()

        DashboardDevicesCard()
    }
}

// MARK: - Dashboard: Status card (separate Server + Remote sections, C23)

/// LAN/Server and Remote/Public are independent. The Server section always works
/// on its own; the Remote section is an optional add-on and shows "Not
/// configured" when no public endpoint exists — it never gates the Server.
private struct ServerRemoteCard: View {
    @EnvironmentObject var tunnel: TunnelController
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var backend: BackendController

    private var hasPublic: Bool { model.urls?.public.enabled == true }

    var body: some View {
        let state = displayState(backend, model)
        SectionCard(title: "Status") {
            // ── Server (LAN / local) — the primary, always-available path ──
            Text("Server").font(.subheadline).fontWeight(.semibold)
            HStack(spacing: 10) {
                StatusDot(on: state.isHealthyDot)
                Text(state.label).font(.headline)
                Spacer()
                if let s = model.status {
                    Text("\(displayVersion(s.version)) · up \(uptime(s.uptimeSeconds))")
                        .foregroundStyle(.secondary)
                }
            }
            // C27: show every VISIBLE LAN address (not just the first interface,
            // and excluding endpoints the user hid in Connections). The first
            // discovered interface isn't necessarily the right route.
            let visibleLANs = model.visibleLANEndpoints
            if !visibleLANs.isEmpty {
                ForEach(Array(visibleLANs.enumerated()), id: \.element.id) { index, lan in
                    LabeledRow(
                        label: index == 0 ? L10n.localized( "LAN address") : "",
                        value: lan.baseUrl)
                }
            }
            if case .failed(let reason) = backend.processState {
                Text(reason).font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let next = backend.nextRestartInfo {
                Text(next).font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            // ── Remote (public / tunnel) — optional ──
            HStack {
                Text("Remote").font(.subheadline).fontWeight(.semibold)
                Spacer()
                Button { tunnel.refreshDiscovery() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }.buttonStyle(.borderless).help("Re-check cloudflared/config")
            }

            if hasPublic || tunnel.installed {
                HStack(spacing: 10) {
                    tunnelStatusChip
                    Spacer()
                }
                if !tunnel.publicURL.isEmpty {
                    CopyableRow(label: "Public URL", value: tunnel.publicURL)
                }
                if let err = tunnel.lastError {
                    Text(err).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Button { tunnel.start() } label: { Label("Start", systemImage: "play.fill") }
                        .disabled(!tunnel.installed || !tunnel.configFound || tunnel.isProcessAlive || tunnel.state == .runningExternally)
                    Button { tunnel.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .disabled(!tunnel.isProcessAlive)
                    Button { tunnel.restart() } label: { Label("Restart", systemImage: "arrow.clockwise") }
                        .disabled(!tunnel.installed || !tunnel.configFound)
                    Spacer()
                }
                // C27: Public URL config + validation is the single source of
                // truth under Connections → Public — not duplicated here.
                Toggle("Start tunnel with the server", isOn: $tunnel.startWithServer)
                    .font(.caption)
                Toggle("Stop tunnel when the server stops", isOn: $tunnel.stopWithServer)
                    .font(.caption)
            } else {
                // No public endpoint and no tunnel — remote access is simply off.
                // LAN/pairing continues to work without it.
                Text("Not set up. LAN pairing works without it. Add a tunnel under Connections for remote access.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var tunnelStatusChip: some View {
        let (color, label): (Color, String) = {
            switch tunnel.state {
            case .stopped: return (.secondary, L10n.localized( "Stopped"))
            case .starting: return (.orange, L10n.localized( "Starting…"))
            case .running: return (.green, L10n.localized( "Running"))
            case .failed: return (.red, L10n.localized( "Failed"))
            case .runningExternally: return (.blue, L10n.localized( "Running externally"))
            case .unknown: return (.secondary, L10n.localized( "Unknown"))
            }
        }()
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label).font(.headline)
        }
    }

    private func uptime(_ seconds: Int64) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}

// MARK: - Dashboard: Devices card

private struct DashboardDevicesCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SectionCard(title: L10n.localized( "Paired Devices (\(model.devices.count))")) {
            if model.devices.isEmpty {
                if model.activeConnections.isEmpty {
                    Text("No devices have registered with the server yet.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Connected sessions")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(model.activeConnections.enumerated()), id: \.element.id) { index, connection in
                        ActiveConnectionRow(connection: connection)
                        if index < model.activeConnections.count - 1 {
                            Divider()
                        }
                    }
                }
            } else {
                Text("\(model.activeConnections.count) active connection\(model.activeConnections.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, device in
                    DeviceCardRow(device: device)
                    if index < model.devices.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }
}

// MARK: - Shared active connection card

private struct ActiveConnectionRow: View {
    let connection: ActiveConnectionInfo

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "network")
                .foregroundStyle(.green)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(connection.displayTitle).fontWeight(.medium)
                Text(connection.subtitle)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 5) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text("Connected").font(.caption).foregroundStyle(.green)
                }
                Text("since: \(connection.connectedLabel)")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("seen: \(connection.lastSeenLabel)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Shared device card (C21u)

/// One paired-device card: "{name} - micaGO {version}" main line, a
/// "mode: …, push: …" secondary line, and a right column with connection state
/// + last-connected time. The top-right edit menu exposes Remove for stale
/// devices. No private data is shown.
private struct DeviceCardRow: View {
    @EnvironmentObject var model: AppModel
    let device: DeviceInfo

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(device.displayTitle).fontWeight(.medium)
                Text("mode: \(device.modeLabel), push: \(device.pushLabel), background: \(device.backgroundLabel)")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(device.isConnected ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(device.awaitingRegistration ? L10n.tr("pairing.awaitingDevice") :
                         (device.isConnected ? L10n.localized("Connected") : L10n.localized("Disconnected")))
                        .font(.caption)
                        .foregroundStyle(device.isConnected ? Color.green : Color.secondary)
                }
                Text("last: \(device.lastConnectedLabel)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Menu {
                Button("Revoke Device Access", role: .destructive) {
                    Task { await model.deleteDevice(deviceID: device.id) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Tutorials

private struct TutorialsPage: View {
    /// The published repo. Guides open on GitHub in the user's browser.
    private static let repoBase = "https://github.com/cinmou/MicaGo/blob/main"

    /// Localized guides ship as `name.zh-Hans.md` / `name.zh-Hant.md` beside the
    /// English `name.md`; English-only guides ignore the suffix.
    private static let entries: [(title: String, subtitle: String, path: String, localized: Bool)] = [
        (L10n.localized( "Getting Started"), L10n.localized( "First setup, permissions, and your first connection."), "docs/getting-started", true),
        (L10n.localized( "Documentation"), L10n.localized( "All user guides in one place."), "docs/index", true),
        (L10n.localized( "Android Client"), L10n.localized( "Pair the Android app with a QR code."), "docs/android-client-connection", false),
        (L10n.localized( "Remote Access"), L10n.localized( "Reach your Mac from anywhere through your own tunnel."), "docs/remote-access-cloudflare", false),
        (L10n.localized( "Notifications"), L10n.localized( "Set up push notifications and fix common problems."), "docs/notifications-setup", false),
    ]

    /// The `.md` filename suffix that matches the user's preferred language, so a
    /// localized guide opens in that language (English guides pass `localized:false`).
    private var docSuffix: String {
        let lang = L10n.languageIdentifier.lowercased()
        if lang.hasPrefix("zh-hant") || lang.hasPrefix("zh-tw") || lang.hasPrefix("zh-hk") {
            return ".zh-Hant"
        } else if lang.hasPrefix("zh") {
            return ".zh-Hans"
        }
        return ""
    }

    private func url(for entry: (title: String, subtitle: String, path: String, localized: Bool)) -> URL? {
        let suffix = entry.localized ? docSuffix : ""
        return URL(string: "\(Self.repoBase)/\(entry.path)\(suffix).md")
    }

    var body: some View {
        SectionCard(title: "Tutorials") {
            Text("User guides on GitHub open in your browser.")
                .foregroundStyle(.secondary)
            Divider()
            ForEach(Self.entries, id: \.title) { entry in
                Button {
                    if let url = url(for: entry) { NSWorkspace.shared.open(url) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "book.closed").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.title).fontWeight(.medium)
                            Text(entry.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                Divider()
            }
            Text("Source: github.com/cinmou/MicaGo")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - About

private struct AboutPage: View {
    private let repoURL = URL(string: "https://github.com/cinmou/MicaGo")!
    @StateObject private var updates = SparkleUpdater.shared

    var body: some View {
        SectionCard(title: "") {
            VStack(spacing: 16) {
                ClickableAppIcon()
                Text("micaGO Companion")
                    .font(.largeTitle)
                    .fontWeight(.bold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }

        SectionCard(title: "About") {
            AboutInfoButton(
                icon: "sparkles",
                title: "Version",
                value: companionVersionLabel
            )
            Divider()
            AboutInfoButton(
                icon: "chevron.left.forwardslash.chevron.right",
                title: "Open Source",
                value: "GitHub",
                accessoryIcon: "arrow.up.right.square"
            ) {
                NSWorkspace.shared.open(repoURL)
            }
            Divider()
            AboutInfoButton(
                icon: "square.and.arrow.down",
                title: "Check for Updates",
                value: "Open updater",
                accessoryIcon: "arrow.clockwise"
            ) {
                updates.checkForUpdates()
            }
        }

        Text("An open source project.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var companionVersionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let cleanVersion = (version?.isEmpty == false ? version : nil) ?? "0.0.0"
        if let build, !build.isEmpty, build != cleanVersion {
            return "Muscovite v\(cleanVersion) (\(build))"
        }
        return "Muscovite v\(cleanVersion)"
    }
}

private struct ClickableAppIcon: View {
    @State private var rotation = 0.0
    @State private var pressed = false

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 104, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .accentColor.opacity(pressed ? 0.28 : 0.16), radius: pressed ? 22 : 14, y: pressed ? 12 : 8)
            .rotation3DEffect(.degrees(rotation), axis: (x: 0.2, y: 1, z: 0))
            .scaleEffect(pressed ? 1.04 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.68), value: rotation)
            .animation(.spring(response: 0.18, dampingFraction: 0.72), value: pressed)
            .onTapGesture {
                pressed = true
                rotation += 360
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    pressed = false
                }
            }
    }
}

private struct AboutInfoButton: View {
    let icon: String
    let title: String
    let value: String
    var accessoryIcon = "chevron.right"
    var action: (() -> Void)? = nil

    var body: some View {
        if let action {
            Button(action: action) {
                row
            }
            .buttonStyle(.plain)
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title)).fontWeight(.medium)
                Text(LocalizedStringKey(value)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if action != nil {
                Image(systemName: accessoryIcon)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}


private struct CapabilitiesCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SectionCard(title: "Detected chat.db Capabilities") {
            if let schema = model.status?.capabilities?.schema {
                CapabilityRow(label: "Edited messages", on: schema.editedMessages)
                CapabilityRow(label: "Unsent / retracted", on: schema.unsentMessages)
                CapabilityRow(label: "Read status", on: schema.readStatus)
                CapabilityRow(label: "Delivered status", on: schema.deliveredStatus)
                CapabilityRow(label: "Send error", on: schema.sendError)
                CapabilityRow(label: "Group actions", on: schema.groupActions)
                CapabilityRow(label: "Attachment metadata", on: schema.attachmentMetadata)
            } else {
                Text("Start the server to read detected capabilities.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct CapabilityRow: View {
    let label: String
    let on: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: on ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(on ? Color.green : Color.secondary)
            Text(LocalizedStringKey(label))
            Spacer()
            Text(on ? L10n.localized( "available") : L10n.localized( "unavailable")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// C26: surfaces whether the bundled IMCore helper that performs edit / unsend /
/// delete is present and runnable. When it is missing or failing the client hides
/// those actions; this card makes the reason visible instead of a silent gap.
private struct MessageActionsCard: View {
    @EnvironmentObject var model: AppModel

    /// True when this macOS itself rules the actions out (either below the
    /// minimum, or new enough that the private IMCore APIs are blocked), so the
    /// card must not advertise an install that can never succeed.
    private var blockedByPlatform: Bool {
        guard let actions = model.status?.messageActions else { return false }
        if actions.platformSupported == false { return true }
        return !(actions.platformWarning ?? "").isEmpty && !actions.available
    }

    var body: some View {
        SectionCard(title: "Message Actions (Edit / Unsend / Delete)") {
            if let actions = model.status?.messageActions {
                let state = HelperUIState(actions)
                HStack(spacing: 8) {
                    if model.helperInstalling {
                        ProgressView().controlSize(.small)
                        Text("Installing…")
                    } else {
                        Image(systemName: state.icon).foregroundStyle(state.color)
                        Text(state.headline)
                    }
                    Spacer()
                }
                if actions.available {
                    CapabilityRow(label: "Edit", on: actions.edit)
                    CapabilityRow(label: "Unsend / retract", on: actions.retract)
                    CapabilityRow(label: "Delete", on: actions.delete)
                }
                if let reason = actions.reason, !reason.isEmpty {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                if let warning = actions.platformWarning, !warning.isEmpty {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if actions.platformSupported == false {
                    Text("Requires macOS \(actions.minimumMacOS ?? "13.0") or newer.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let helper = actions.helper, !helper.isEmpty {
                    Text("Helper: \(helper)").font(.caption2).foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                // C79: don't offer an install that cannot work. When this macOS
                // blocks the private IMCore APIs the only useful action is
                // removing a helper installed on an older system.
                HStack(spacing: 8) {
                    if !actions.available && !blockedByPlatform {
                        Button {
                            model.installIMCoreHelper()
                        } label: {
                            if model.helperInstalling {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Install helper", systemImage: "arrow.down.circle")
                            }
                        }
                        .disabled(model.helperInstalling)
                    }
                    if !actions.available || blockedByPlatform {
                        // Manual re-scan: force a fresh probe without re-installing
                        // (e.g. after manually placing the helper).
                        Button {
                            model.rescanIMCoreHelper()
                        } label: {
                            Label("Re-scan", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.helperInstalling)
                    }
                    if model.helperInstalledOnDisk {
                        Button(role: .destructive) {
                            model.uninstallIMCoreHelper()
                        } label: {
                            Label("Uninstall helper", systemImage: "trash")
                        }
                        .disabled(model.helperInstalling)
                    }
                    Spacer()
                }
                .padding(.top, 2)
                if let msg = model.helperInstallMessage, !msg.isEmpty {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Start the server to read the message-action helper status.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Maps the helper state to a clear icon/colour/headline (C28): missing,
/// installed-but-not-runnable, runnable-but-unsupported, or ready.
private struct HelperUIState {
    let icon: String
    let color: Color
    let headline: String

    init(_ actions: MessageActionsStatus) {
        switch actions.state {
        case "ready":
            icon = "checkmark.circle.fill"; color = .green
            headline = L10n.localized( "IMCore helper is ready")
        case "not_runnable":
            icon = "exclamationmark.octagon.fill"; color = .orange
            headline = L10n.localized( "Helper installed but not runnable")
        case "unsupported_selectors":
            icon = "exclamationmark.triangle.fill"; color = .orange
            headline = L10n.localized( "Not available on this version of macOS")
        default: // missing or unknown
            icon = "arrow.down.circle"; color = .secondary
            headline = L10n.localized( "IMCore helper not installed, so these actions are hidden in the app")
        }
    }
}

// MARK: - Connections page

private struct ConnectionsPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var backend: BackendController

    var body: some View {
        ConnectionEndpointsSection()
        // C18: the server bind address is a connection concern; it moved here
        // from the dissolved Server page.
        ServerBindAddressCard()
            .onAppear { Task { await model.refresh() } }
            .onChange(of: backend.processState) { _ in
                Task { await model.refresh() }
            }
    }
}

private struct RuntimeCard: View {
    @EnvironmentObject var runtime: RuntimeMonitor

    var body: some View {
        SectionCard(title: "Runtime") {
            HStack(spacing: 8) {
                StatusDot(on: runtime.messagesRunning)
                Text("Messages.app")
                Text(runtime.messagesRunning ? L10n.localized( "running") : L10n.localized( "not running"))
                    .font(.caption)
                    .foregroundStyle(runtime.messagesRunning ? Color.secondary : Color.orange)
                Spacer()
                if !runtime.messagesRunning {
                    Button("Open Messages") { runtime.openMessages() }
                }
            }
            Text("Messages.app must be running to send messages.")
                .font(.caption2).foregroundStyle(.secondary)

            Divider()

            Toggle(isOn: Binding(
                get: { runtime.keepAwakeActive },
                set: { runtime.setKeepAwake($0) }
            )) {
                Text("Keep this Mac awake while serving")
            }
            Text("Status: \(runtime.keepAwakeActive ? L10n.localized( "active (power assertion)") : L10n.localized( "off"))")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// C18: the Server page was dissolved — its Server Runtime card duplicated the
// Dashboard Status card and the toolbar start/stop control. Live Sync Monitor
// → Dashboard, bind address → Connections, binary path/identity → Advanced.

/// C11 live sync monitor: shows chat.db/WAL/SHM mtimes, last sync trigger /
/// timing / result, pending triggers, lock retries, pending/late sends, and the
/// last emitted event. "Run sync now" + "Copy diagnostics" for debugging.
/// Tokens and full message text are never shown.
private struct LiveSyncMonitorCard: View {
    @EnvironmentObject var model: AppModel

    private func t(_ ms: Int64?) -> String {
        guard let ms, ms > 0 else { return "—" }
        let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    var body: some View {
        SectionCard(title: "Live Sync Monitor") {
            let d = model.syncDiagnostics
            HStack(spacing: 10) {
                StatusDot(on: model.reachable)
                Text(model.reachable ? L10n.localized( "Server running") : L10n.localized( "Server unreachable"))
                    .font(.headline)
                Spacer()
                if model.syncNowBusy { ProgressView().controlSize(.small) }
                Button { Task { await model.runSyncNow() } } label: {
                    Label("Run sync now", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(model.syncNowBusy || !model.reachable)
                Button { copyToPasteboard(model.syncDiagnosticsText) } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }

            if let d {
                LabeledRow(label: "Last trigger", value: d.lastTriggerReason ?? "—")
                LabeledRow(label: "Last sync", value: t(d.lastCompletedAt))
                LabeledRow(label: "Duration", value: "\(d.lastDurationMillis ?? 0) ms")
                LabeledRow(label: "Inserted / updated / unsent",
                           value: "\(d.lastInsertedMessages ?? 0) / \(d.lastUpdatePassCount ?? 0) / \(d.lastUnsentCount ?? 0)")
                LabeledRow(label: "chat.db / WAL / SHM mtime",
                           value: "\(t(d.lastChatDbMtime)) / \(t(d.lastWalMtime)) / \(t(d.lastShmMtime))")
                LabeledRow(label: "Pending triggers / lock retries",
                           value: "\(d.pendingTriggerCount ?? 0) / \(d.lockRetryCount ?? 0)")
                LabeledRow(label: "Pending / late-matched sends",
                           value: "\(d.pendingSendsCount ?? 0) / \(d.lateMatchedSendsCount ?? 0)")
                LabeledRow(label: "Last event",
                           value: "\(d.lastEmittedEventType ?? "—") \(d.lastEmittedChatGuid ?? "")")
                if let err = d.lastSyncError, !err.isEmpty {
                    Text("Last error: \(err)").font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("No sync diagnostics yet. Start the server and trigger a sync.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Diagnostics only. Tokens and message text are never shown.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct BinaryPathRow: View {
    @EnvironmentObject var backend: BackendController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Backend binary")
                .font(.caption).fontWeight(.medium)
            HStack(spacing: 8) {
                Image(systemName: backend.binaryExists ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(backend.binaryExists ? .green : .orange)
                TextField("Bundled backend (leave empty)", text: $backend.userBinaryPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                Button("Choose…") { chooseBinary() }
                    .controlSize(.small)
            }
            Text("Advanced. You normally don't need to change this, since micaGO uses the bundled backend.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(resolvedDescription)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            // C27: the stale-binary warning lives once, in the Backend Build card
            // below — not duplicated here.
        }
        .padding(.top, 4)
    }

    private var resolvedDescription: String {
        if let r = backend.resolveBinary() {
            return L10n.localized( "Using \(r.source) binary: \(r.path)")
        }
        return L10n.localized( "No runnable backend found. The bundled binary is missing and no valid path is set.")
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            backend.userBinaryPath = url.path
        }
    }
}

// MARK: - Server Bind Address

private enum BindMode: String, CaseIterable, Identifiable {
    // C25: "This Mac only" (loopback) was removed — it can't be paired from
    // Android. LAN is the default; Custom remains for advanced interface binds.
    case localNetwork, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .localNetwork: return L10n.localized( "Local network")
        case .custom: return L10n.localized( "Custom")
        }
    }
}

private struct ServerBindAddressCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var backend: BackendController

    @State private var mode: BindMode = .localNetwork
    @State private var host: String = "0.0.0.0"
    @State private var port: String = "3000"
    @State private var loaded = false
    @State private var didAutoApplyLANBind = false

    var body: some View {
        SectionCard(title: "Server Bind Address") {
            Text("micaGO listens on your local network so devices on the same Wi‑Fi can connect. This applies to the server Companion starts.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("", selection: $mode) {
                ForEach(BindMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: mode) { newMode in applyModeDefaults(newMode) }

            Text(explanation)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if mode == .custom {
                    TextField("Host", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: 180)
                }
                Text("Port").foregroundStyle(.secondary)
                TextField("3000", text: $port)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: 90)
                Spacer()
            }

            if mode == .custom {
                Text("Examples: 192.168.1.23:3000 · 0.0.0.0:3000")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            // C25: show the real Android-usable LAN address, not the raw bind
            // (0.0.0.0 is not an address a device can connect to).
            if let lan = model.urls?.lan.first {
                Text("Devices connect to: \(lan.baseUrl)")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.status?.address.listen.isEmpty == false {
                Text("Listening, but no LAN address was found. Check that this Mac is on Wi‑Fi or Ethernet.")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("Server is not running. The change applies the next time it starts.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if restartRequired {
                Text("Restart required for this change to take effect.")
                    .font(.caption).foregroundStyle(.orange)

                HStack(spacing: 12) {
                    Button { saveAndRestart() } label: { Label("Save & Restart", systemImage: "arrow.clockwise") }
                        .disabled(!isValid || !backend.binaryExists || displayState(backend, model) == .externalUnmanaged)
                    Spacer()
                }
            }

            if displayState(backend, model) == .externalUnmanaged {
                Text("Companion didn't start this server, so it can't change the bind address.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: loadInitial)
        .onChange(of: model.status?.address.listen ?? "") { _ in
            autoApplyDefaultLANBindIfNeeded()
        }
    }

    private var explanation: String {
        switch mode {
        case .localNetwork:
            return L10n.localized( "Devices on the same Wi‑Fi use the LAN address shown above. Recommended.")
        case .custom:
            return L10n.localized( "Listen on one interface address. Only use this if you know which interface to pick.")
        }
    }

    private var portNumber: Int? {
        guard let n = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(n) else { return nil }
        return n
    }

    private var isValid: Bool {
        guard portNumber != nil else { return false }
        if mode == .custom {
            return !host.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    private var desiredAddress: String {
        let p = port.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .localNetwork: return "0.0.0.0:\(p)"
        case .custom: return "\(host.trimmingCharacters(in: .whitespaces)):\(p)"
        }
    }

    private var restartRequired: Bool {
        guard isValid else { return false }
        if let listen = model.status?.address.listen, !listen.isEmpty {
            return desiredAddress != listen
        }
        // Server not running: compare against the persisted launch value.
        return desiredAddress != backend.effectiveBindAddress
    }

    private func loadInitial() {
        guard !loaded else { return }
        loaded = true
        let liveListen = model.status?.address.listen ?? ""
        let source = liveListen.isEmpty ? backend.effectiveBindAddress : liveListen
        let (h, p) = splitHostPort(source)
        host = h.isEmpty ? "0.0.0.0" : h
        port = p.isEmpty ? "3000" : p
        switch host {
        // C25: loopback-only is no longer a user choice — treat any existing
        // loopback/wildcard bind as "Local network" (it saves as 0.0.0.0).
        case "0.0.0.0", "", "127.0.0.1", "localhost", "::1": mode = .localNetwork
        default: mode = .custom
        }
        autoApplyDefaultLANBindIfNeeded()
    }

    private func applyModeDefaults(_ newMode: BindMode) {
        switch newMode {
        case .localNetwork: host = "0.0.0.0"
        case .custom:
            if host == "0.0.0.0" { /* keep as a starting point */ }
        }
    }

    private func saveAndRestart() {
        backend.bindAddress = desiredAddress
        backend.restart()
    }

    private func autoApplyDefaultLANBindIfNeeded() {
        guard !didAutoApplyLANBind else { return }
        guard displayState(backend, model) != .externalUnmanaged else { return }
        guard mode == .localNetwork, isValid, restartRequired else { return }
        didAutoApplyLANBind = true
        saveAndRestart()
    }
}

/// Splits "host:port" (IPv4/hostname) into components. Leaves host empty for a
/// bare ":port". Falls back gracefully for unexpected input.
private func splitHostPort(_ value: String) -> (String, String) {
    guard let idx = value.lastIndex(of: ":") else { return (value, "") }
    let host = String(value[value.startIndex..<idx])
    let port = String(value[value.index(after: idx)...])
    return (host, port)
}

// MARK: - Logs page

private struct LogsPage: View {
    @EnvironmentObject var backend: BackendController

    var body: some View {
        SectionCard(title: "Server Log") {
            if backend.logLines.isEmpty {
                Text("No output yet. The log shows output from a server Companion started. Tokens are hidden.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(backend.logLines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 320)
            }
        }
    }
}

// MARK: - Advanced page (general lifecycle/login + diagnostics)

private struct AdvancedPage: View {
    @AppStorage(L10n.languageKey) private var appLanguage = "system"
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var backend: BackendController

    var body: some View {
        // C23 cleanup: "Startup & Lifecycle" + "Launch at Login" merged into one
        // section. General app/server lifecycle + login behavior only.
        SectionCard(title: L10n.localized( "settings.general.title")) {
            Picker(L10n.tr("language.title"), selection: $appLanguage) {
                Text(L10n.tr("language.system")).tag("system")
                Text("English").tag("en")
                Text("简体中文").tag("zh-Hans")
                Text("繁體中文").tag("zh-Hant")
            }
            .pickerStyle(.menu)
            Text(L10n.tr("language.help"))
                .font(.caption2).foregroundStyle(.secondary)
            Divider()
            LaunchAtLoginControls()
            Toggle(L10n.localized( "settings.server.lifecycleWithApp"), isOn: $backend.manageLifecycleWithApp)
            Toggle(L10n.localized( "settings.server.restartOnCrash"), isOn: $backend.autoRestart)
            Toggle(L10n.localized( "settings.app.launchHidden"), isOn: $backend.launchHidden)
            Toggle(L10n.localized( "settings.app.hideDockIcon"), isOn: $backend.hideDockIcon)
                .onChange(of: backend.hideDockIcon) { _ in
                    // Apply immediately: turning it off restores the Dock icon now.
                    applyActivationPolicy()
                }
            Text(L10n.localized( "settings.server.restartHelp"))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        SectionCard(title: L10n.localized( "settings.developer.title")) {
            HStack {
                Label(
                    model.developerModeEnabled
                        ? L10n.localized( "settings.developer.enabled")
                        : L10n.localized( "settings.developer.off"),
                    systemImage: model.developerModeEnabled ? "checkmark.circle.fill" : "hammer"
                )
                .foregroundStyle(model.developerModeEnabled ? Color.green : Color.secondary)
                Spacer()
                Button(model.developerModeEnabled
                    ? L10n.localized( "settings.developer.disable")
                    : L10n.localized( "settings.developer.enable")
                ) {
                    model.developerModeEnabled.toggle()
                }
            }
            Text(L10n.localized( "settings.developer.help"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }

        // Permissions + runtime + detected chat.db capabilities — diagnostics.
        if fdaNeeded(backend, model) {
            FullDiskAccessBanner()
        }
        DiagnosticsSection()
        RuntimeCard()
        CapabilitiesCard()
        MessageActionsCard()

        // C23 cleanup: backend/file paths only. Connection settings (preferred
        // pairing, verify TLS, public URL) live on the Connections page — not
        // duplicated here.
        SectionCard(title: "Files & Paths") {
            LabeledRow(label: "Config file", value: "~/.micago/config.yaml")
            // C27: the backend binary's source/path/version is shown once, in the
            // Backend Build card below (Executable + Selected binary). Here we
            // only keep the editable override picker.
            BinaryPathRow()
        }

        BackendIdentityCard()
    }
}

/// C17: proves WHICH backend binary is running — version/commit/build time,
/// executable + DB paths, and the chat.db open options (immutable must be
/// absent). Warns loudly when the launched or selected binary is stale.
private struct BackendIdentityCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var backend: BackendController

    var body: some View {
        SectionCard(title: "Backend Build") {
            if let warning = backend.staleBinaryWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let b = model.status?.backend {
                LabeledRow(label: "Running version", value: "\(displayVersion(b.version)) (\(b.commit))")
                LabeledRow(label: "Built", value: b.buildTime)
                LabeledRow(label: "Toolchain", value: "\(b.goVersion) \(b.osArch)")
                LabeledRow(label: "Executable", value: b.executablePath)
                LabeledRow(label: "Relay DB", value: b.relayDbPath)
                LabeledRow(label: "chat.db", value: b.chatDbPath)
                LabeledRow(label: "chat.db open", value: b.chatDbOpenOptions)
                if b.chatDbImmutable {
                    Label("The running backend opens chat.db with immutable=1, so it predates the malformed-database fix. Restart it with the latest backend.",
                          systemImage: "exclamationmark.octagon.fill")
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let s = model.status?.sync.settings {
                    LabeledRow(label: "Backfill", value: "\(s.backfillMode) (\(s.recentMessagesPerChat)/chat)")
                }
            } else if model.status != nil {
                Label("The running server doesn't report its build, so it predates v0.15 and lacks recent sync fixes. Restart it with the latest backend.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Server not reachable. Start it to see the running build.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let line = backend.launchedVersionLine {
                LabeledRow(label: "Selected binary", value: line)
            }
            HStack(spacing: 8) {
                Button("Restart with Latest Backend") {
                    backend.restartWithLatestBackend()
                }
                .controlSize(.small)
                Button("Open Backend Location") {
                    backend.revealBinaryInFinder()
                }
                .controlSize(.small)
                Button("Check Freshness") {
                    backend.refreshBinaryFreshness()
                }
                .controlSize(.small)
            }
            .padding(.top, 2)
        }
    }
}

// MARK: - Connection Endpoints

private struct ConnectionEndpointsSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SectionCard(title: "Connection Endpoints") {
            // C25: LAN is the primary, Android-usable path. Loopback is not shown
            // — Android can't reach 127.0.0.1.
            EndpointGroupHeader(
                title: "LAN / same Wi‑Fi",
                subtitle: "The address devices on the same Wi‑Fi use to connect. Hide VPN or virtual addresses so they aren’t offered for pairing.")
            if let urls = model.urls, !urls.lan.isEmpty {
                ForEach(urls.lan) { LANEndpointRow(endpoint: $0) }
                if !model.hiddenLANBaseURLs.isEmpty {
                    Button("Reset hidden LAN endpoints (\(model.hiddenLANBaseURLs.count))") {
                        model.resetHiddenLANEndpoints()
                    }
                    .controlSize(.small).font(.caption)
                }
            } else {
                Text("No LAN address available. Make sure this Mac is on Wi‑Fi or Ethernet. A VPN-only address won’t work.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            EndpointGroupHeader(
                title: "Public / remote",
                subtitle: "Optional, for access outside your Wi‑Fi. LAN works without it.")
            PublicURLEditor()
        }
    }
}

private struct EndpointGroupHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(title)).font(.subheadline).fontWeight(.semibold)
            Text(LocalizedStringKey(subtitle)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


/// A LAN endpoint row with a hide-from-pairing toggle. Hiding is a UI/pairing
/// filter only — it never changes server networking.
private struct LANEndpointRow: View {
    @EnvironmentObject var model: AppModel
    let endpoint: ConnectionEndpoint

    var body: some View {
        let hidden = model.isLANHidden(endpoint.baseUrl)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ReachableDot(endpoint.reachable)
                Text(endpoint.label).font(.caption).foregroundStyle(.secondary)
                if hidden {
                    Text("hidden from pairing").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.setLANHidden(endpoint.baseUrl, hidden: !hidden)
                } label: {
                    Image(systemName: hidden ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(hidden ? L10n.localized( "Show this address for pairing") : L10n.localized( "Hide this address from pairing"))
            }
            EndpointURLRow(label: "Base", value: endpoint.baseUrl)
            EndpointURLRow(label: "WS", value: endpoint.wsUrl)
        }
        .opacity(hidden ? 0.55 : 1)
        .padding(.vertical, 2)
    }
}

/// A monospaced URL with a copy button, used across endpoint cards.
private struct EndpointURLRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button { copyToPasteboard(value) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .disabled(value.isEmpty)
        }
    }
}

private struct PublicURLEditor: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("https://micago.example.com", text: $model.publicURLInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))

            Text("Enter only the origin, without /api, /ws, or any other path.")
                .font(.caption2).foregroundStyle(.secondary)

            if let warning = originWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button("Save") { Task { await model.savePublicURL() } }
                    .disabled(model.publicBusy || originWarning != nil)
                Button("Validate Public URL") { Task { await model.validatePublicURL() } }
                    .disabled(model.publicBusy || (model.urls?.public.enabled != true))
                if model.publicBusy { ProgressView().controlSize(.small) }
                Spacer()
                if let pub = model.urls?.public, pub.enabled {
                    Button { copyToPasteboard(pub.baseUrl) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                }
            }

            // C27: ONE Public-URL status line — the single source of truth. It
            // prefers the detailed last-validation result, falling back to the
            // server's cached reachability when nothing has been validated yet.
            if let status = publicStatusLine {
                HStack(spacing: 6) {
                    Text("Public status:").font(.caption).foregroundStyle(.secondary)
                    Label(status.text, systemImage: status.system)
                        .font(.caption).foregroundStyle(status.color)
                        .fixedSize(horizontal: false, vertical: true)
                    if let pub = model.urls?.public, pub.enabled,
                       let hint = pub.providerHint, hint != "custom" {
                        Text("· \(providerLabel(hint))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if let pub = model.urls?.public, pub.enabled {
                Text(pub.baseUrl).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            Text("Optional extra endpoint. LAN keeps working without it.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The single Public-URL status line: the detailed last-validation result
    /// when present, else the server's cached reachability.
    private var publicStatusLine: (text: String, color: Color, system: String)? {
        if let d = publicDiagnostic {
            return (d.text, d.ok ? .green : .orange,
                    d.ok ? "checkmark.circle" : "exclamationmark.triangle")
        }
        guard let pub = model.urls?.public, pub.enabled else {
            return (L10n.localized( "Not configured"), .secondary, "minus.circle")
        }
        switch pub.reachable {
        case .yes: return (L10n.localized( "Reachable"), .green, "checkmark.circle")
        case .no: return (L10n.localized( "Not reachable. Validate to see why."), .orange, "exclamationmark.triangle")
        case .unknown: return (L10n.localized( "Not validated yet"), .secondary, "questionmark.circle")
        }
    }

    /// Plain-language result of the last "Validate Public URL" check. Never
    /// includes the token. Maps HTTP statuses to actionable messages.
    private var publicDiagnostic: (text: String, ok: Bool)? {
        guard let r = model.publicCheckResult else { return nil }
        if r.ok {
            return (L10n.localized( "Reachable, and the token was accepted. Public is ready for pairing."), true)
        }
        if !r.reachable {
            return (L10n.localized( "Couldn’t reach the public URL. Check that the tunnel is running and forwards to this server’s port."), false)
        }
        switch r.status {
        case 401, 403:
            return (L10n.localized( "Reached a server, but it rejected the token (\(r.status)). The public URL may point to another server."), false)
        case 502, 503, 504:
            return (L10n.localized( "The tunnel answered, but no server is behind it (\(r.status)). Make sure micaGO is running and the tunnel forwards to its port."), false)
        default:
            return (r.message.isEmpty ? L10n.localized( "Validation failed (HTTP \(r.status)).") : r.message, false)
        }
    }

    private func providerLabel(_ hint: String) -> String {
        switch hint {
        case "cloudflare_tunnel": return "Cloudflare Tunnel"
        case "ngrok": return "Ngrok"
        case "tailscale": return "Tailscale"
        default: return hint
        }
    }

    /// A non-nil warning means the entered text is not a bare http(s) origin.
    /// An empty field is allowed (it clears the public URL).
    private var originWarning: String? {
        let raw = model.publicURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return nil }
        guard let comps = URLComponents(string: raw),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty else {
            return L10n.localized( "Enter a full origin like https://micago.example.com")
        }
        if !(comps.path.isEmpty || comps.path == "/") {
            return L10n.localized( "Remove the path. Enter only the origin, without /api, /ws, or any other path.")
        }
        if comps.query != nil || comps.fragment != nil {
            return L10n.localized( "Remove the query or fragment. Enter only the origin.")
        }
        return nil
    }
}

private struct ReachableDot: View {
    let reachable: Reachability
    init(_ reachable: Reachability) { self.reachable = reachable }

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }

    private var color: Color {
        switch reachable {
        case .yes: return .green
        case .no: return .red
        case .unknown: return .secondary
        }
    }
}

// MARK: - Create Connection (C23 — one canonical pairing card)

/// The single place to set up a client. Encodes ONE unified connection payload
/// (all candidates + token + config revision) into a QR code and a copyable
/// JSON. No LAN-only vs LAN+Public mode picker — the client auto-selects. No
/// long explanations; per-endpoint rows live in an expandable detail only.
private struct CreateConnectionCard: View {
    @EnvironmentObject var model: AppModel

    private var hasEndpoint: Bool { model.hasLanCandidate || model.hasPublicCandidate }
    private func ready(at date: Date) -> Bool {
        model.pairingState == "active" && !model.pairingCode.isEmpty && hasEndpoint &&
            model.pairingExpiresAt > Int64(date.timeIntervalSince1970 * 1000)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let ready = ready(at: context.date)
            SectionCard(title: "Create Connection") {
                if ready {
                    if model.pairingPayload != "{}", let image = QRCode.image(from: model.pairingPayload) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 200, height: 200)
                    }
                    HStack(spacing: 12) {
                        StatusFlag(on: model.hasLanCandidate, label: "LAN")
                        StatusFlag(on: model.hasPublicCandidate, label: "Public")
                        StatusFlag(on: true, label: "Pairing code")
                    }.font(.caption)
                    let seconds = max(0, Int(ceil(Double(model.pairingExpiresAt) / 1000 - context.date.timeIntervalSince1970)))
                    Text(String(format: L10n.tr("pairing.remaining"), String(format: "%d:%02d", seconds / 60, seconds % 60)))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Text(statusMessage(at: context.date))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { pairingActions(ready: ready) }
                    VStack(alignment: .leading, spacing: 10) { pairingActions(ready: ready) }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
    }

    @ViewBuilder private func pairingActions(ready: Bool) -> some View {
        Button {
            let payload = model.pairingPayload
            if payload != "{}" { copyToPasteboard(payload) }
        } label: {
            Label("Copy connection JSON", systemImage: "doc.on.doc")
        }.disabled(!ready)
        Button {
            Task { await model.refreshPairingCode() }
        } label: {
            Label("New pairing code", systemImage: "arrow.clockwise")
        }.disabled(!hasEndpoint || !model.reachable)
    }

    private func statusMessage(at date: Date) -> String {
        if model.pairingState == "used" { return L10n.tr("pairing.used") }
        if model.pairingState == "invalidated" { return L10n.tr("pairing.invalidated") }
        if model.pairingState == "expired" ||
            (model.pairingExpiresAt > 0 && model.pairingExpiresAt <= Int64(date.timeIntervalSince1970 * 1000)) {
            return L10n.tr("pairing.expired")
        }
        if model.token.isEmpty { return L10n.localized("Start the server to generate a connection.") }
        if hasEndpoint { return L10n.localized("Create a new pairing code to connect a device.") }
        if model.urls != nil {
            return L10n.localized("No endpoint devices can use yet. Put this Mac on Wi‑Fi or Ethernet, or set up Public for remote access.")
        }
        return L10n.localized("No endpoint devices can use yet.")
    }
}

/// A small "Name ✓/✗" capability flag for the Create Connection status line.
private struct StatusFlag: View {
    let on: Bool
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: on ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(on ? Color.green : Color.secondary)
            Text(LocalizedStringKey(label)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Devices

// MARK: - Notifications

private struct NotificationsSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SectionCard(title: "Notification Providers") {
            if let n = model.status?.notifications {
                LabeledRow(label: "Enabled", value: n.enabled ? L10n.localized( "yes") : L10n.localized( "no"))
                LabeledRow(label: "Provider", value: n.provider)
                LabeledRow(label: "Client config", value: (n.fcmClientConfigured ?? false) ? L10n.localized( "configured") : L10n.localized( "not set"))
                LabeledRow(label: "Service account", value: (n.fcmServiceAccountConfigured ?? false) ? L10n.localized( "configured") : L10n.localized( "not set"))
                LabeledRow(label: "Implemented", value: n.implemented.joined(separator: ", "))
                LabeledRow(label: "Stub", value: n.stub.isEmpty ? "—" : n.stub.joined(separator: ", "))
            } else {
                Text("Unavailable.").foregroundStyle(.secondary)
            }
            Text("Read-only. Set up Firebase (FCM) on the Notifications page.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Diagnostics

private struct DiagnosticsSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SectionCard(title: "Permission Diagnostics") {
            if let p = model.status?.permissions {
                PermissionRow(label: "Full Disk Access", check: p.fullDiskAccess)
                PermissionRow(label: "Attachments", check: p.attachments)
                PermissionRow(label: "Automation", check: p.automation)
            } else {
                Text("Start the server to read diagnostics.").foregroundStyle(.secondary)
            }
        }
    }
}

private struct PermissionRow: View {
    let label: String
    let check: PermissionCheck

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(LocalizedStringKey(label)).fontWeight(.medium)
                    Text(check.status).font(.caption).foregroundStyle(color)
                }
                if let detail = check.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch check.status {
        case "ok": return "checkmark.circle.fill"
        case "denied": return "xmark.circle.fill"
        default: return "questionmark.circle.fill"
        }
    }
    private var color: Color {
        switch check.status {
        case "ok": return .green
        case "denied": return .red
        default: return .secondary
        }
    }
}

// MARK: - Launch at login

/// C23 cleanup: login-at-launch controls without their own card, so they live
/// inside the merged "General Settings" section.
private struct LaunchAtLoginControls: View {
    @State private var enabled = LaunchAtLogin.isEnabled
    @State private var error: String?

    var body: some View {
        Toggle(isOn: $enabled) {
            Text(L10n.localized( "settings.login.startAtLogin"))
        }
        .disabled(!LaunchAtLogin.isSupported)
        .onChange(of: enabled) { newValue in
            do {
                try LaunchAtLogin.set(newValue)
                error = nil
            } catch {
                self.error = error.localizedDescription
                enabled = LaunchAtLogin.isEnabled
            }
        }
        Text("\(L10n.localized( "settings.login.status")): \(LaunchAtLogin.statusDescription)")
            .font(.caption).foregroundStyle(.secondary)
        if let error {
            Text(error).font(.caption).foregroundStyle(.orange)
        }
    }
}

// MARK: - Reusable pieces

struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                Text(LocalizedStringKey(title)).font(.title3).fontWeight(.semibold)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

struct LabeledRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(LocalizedStringKey(label)).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }
}

struct CopyableRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(LocalizedStringKey(label)).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                copyToPasteboard(value)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .disabled(value == "—" || value == "not configured")
        }
    }
}

struct StatusDot: View {
    let on: Bool
    var body: some View {
        Circle()
            .fill(on ? Color.green : Color.secondary)
            .frame(width: 10, height: 10)
    }
}

func copyToPasteboard(_ value: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(value, forType: .string)
}

#Preview {
    ContentView()
        .environmentObject(AppModel())
        .environmentObject(RuntimeMonitor())
        .environmentObject(BackendController.shared)
        .environmentObject(ContactsStore())
}

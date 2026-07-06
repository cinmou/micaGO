import Foundation
import Combine

/// Central observable state for the companion UI. Owns the server controller,
/// reads the config/token, and periodically polls the local control API while
/// the window is visible.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var config: MicaConfig?
    @Published var reachable = false
    @Published var authValid = false
    @Published var status: ServerStatus?
    @Published var devices: [DeviceInfo] = []
    @Published var activeConnections: [ActiveConnectionInfo] = []
    @Published var lastError: String?
    /// C36: a failure from the 3s background poll's best-effort diagnostic fetches
    /// (status / connections / devices / urls). Recorded for Debug only — it must
    /// NOT become a user-facing error banner, because the server is already
    /// reachable + authed. (It used to leak into `lastError` and show up in the
    /// Sync Control header as a spurious "Server returned HTTP 500".)
    @Published var lastPollError: String?
    @Published var developerModeEnabled: Bool {
        didSet { UserDefaults.standard.set(developerModeEnabled, forKey: "developerModeEnabled") }
    }

    // Connection endpoints (v0.11)
    @Published var urls: ServerURLs?
    @Published var publicURLInput: String = ""
    @Published var publicVerifyTLS: Bool = true
    @Published var publicCheckResult: PublicURLCheckResult?
    @Published var publicBusy = false

    // C26: IMCore helper install flow. `helperInstalling` drives the button
    // spinner; `helperInstallMessage` shows the result/error. The helper status
    // itself is read from `status?.messageActions` (server capability probe).
    @Published var helperInstalling = false
    @Published var helperInstallMessage: String?

    // C23 cleanup: the per-pairing LAN selection (`selectedPairingBaseURL`),
    // the `pairingMode` (lanOnly/lanFirst), `selectedPairingTarget`, and
    // `tokenRevealed` were removed. The unified v3 payload includes every LAN
    // candidate plus Public when configured — there is no manual mode or
    // single-LAN selection anymore.

    /// LAN base URLs the user has hidden from pairing/QR selection. This is a
    /// UI/pairing filter only — it does not change server networking; the
    /// endpoints remain present in `GET /api/server/urls`.
    @Published var hiddenLANBaseURLs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "hiddenLANEndpoints") ?? [])

    private var pollTask: Task<Void, Never>?
    private var startupRefreshTask: Task<Void, Never>?
    private let pollInterval: UInt64 = 3 * 1_000_000_000 // 3s
    // The server's saved Public URL we last mirrored into `publicURLInput`. Used
    // to detect unsaved user edits so a poll doesn't clobber them, while still
    // re-syncing the field when the saved value changes (e.g. after restart).
    private var lastSeededPublicURL = ""

    init() {
        developerModeEnabled = UserDefaults.standard.bool(forKey: "developerModeEnabled")
        reloadConfig()
    }

    // Notifications / FCM config (v0.12)
    @Published var notifEnabled = false
    @Published var notifProvider = "none"
    @Published var notifPreview = "sender_and_text"
    @Published var fcmEnabled = false
    @Published var fcmProjectID = ""
    @Published var serviceAccountPath = ""
    @Published var googleServicesPath = ""
    @Published var firestoreURLSync = false
    @Published var notifBusy = false
    @Published var notifResult: String?
    @Published var firestoreSyncActive = false
    private var didSeedNotif = false

    // Sync control (v0.11.3)
    @Published var syncRules: SyncRulesResponse?
    @Published var chatsList: [ChatSummary] = []
    @Published var syncBusy = false
    @Published var syncSettings: SyncSettings = .defaults
    /// Non-nil when `loadSyncControl` failed; drives the Sync Control error card
    /// (Retry + Copy diagnostics) instead of a bare inline HTTP-status line.
    @Published var syncControlError: String?

    // C11 live sync monitor
    @Published var syncNowBusy = false
    @Published var lastSyncDiagnostics: SyncDiagnostics?
    private var lastSyncedContactCacheSignature: Int?

    /// Effective sync diagnostics: the last manual run, else the live status poll.
    var syncDiagnostics: SyncDiagnostics? { lastSyncDiagnostics ?? status?.sync.diagnostics }

    /// Triggers an immediate server sync (C11 debug) and refreshes status.
    func runSyncNow() async {
        guard let baseURL else { return }
        syncNowBusy = true
        defer { syncNowBusy = false }
        let client = APIClient(baseURL: baseURL, token: token)
        do {
            lastSyncDiagnostics = try await client.runSyncNow()
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Redaction-safe, copyable diagnostics text (no token, no message text).
    var syncDiagnosticsText: String {
        guard let d = syncDiagnostics else { return "No sync diagnostics yet." }
        func ms(_ v: Int64?) -> String { v.map { "\($0)" } ?? "—" }
        return """
        micaGO sync diagnostics
        lastTrigger: \(d.lastTriggerReason ?? "—")
        lastStartedAt: \(ms(d.lastStartedAt))  lastCompletedAt: \(ms(d.lastCompletedAt))
        lastDurationMs: \(ms(d.lastDurationMillis))
        mode: \(d.lastBackfillMode ?? "—")  perChatLimit: \(d.lastPerChatLimit ?? 0)
        inserted: \(d.lastInsertedMessages ?? 0)  synced: \(d.lastSyncedMessages ?? 0)  rowsScanned: \(d.lastRowsScanned ?? 0)
        renderable: \(d.lastRenderableRows ?? 0)  hiddenDebug: \(d.lastHiddenDebugRows ?? 0)  updates: \(d.lastUpdatePassCount ?? 0)  unsent: \(d.lastUnsentCount ?? 0)
        scannedRowId: \(ms(d.lastScannedMessageRowId))
        chatDbMtime: \(ms(d.lastChatDbMtime))  walMtime: \(ms(d.lastWalMtime))  shmMtime: \(ms(d.lastShmMtime))
        pendingTriggers: \(d.pendingTriggerCount ?? 0)  lockRetries: \(d.lockRetryCount ?? 0)
        pendingSends: \(d.pendingSendsCount ?? 0)  lateMatchedSends: \(d.lateMatchedSendsCount ?? 0)
        lastEvent: \(d.lastEmittedEventType ?? "—")  chat: \(d.lastEmittedChatGuid ?? "—")
        lastError: \(d.lastSyncError ?? "—")
        """
    }

    var baseURL: URL? {
        guard let config else { return nil }
        return ConfigReader.baseURL(for: config)
    }

    var token: String { config?.token ?? "" }

    /// All endpoints the user can pick for pairing: local, LAN, and public (if
    /// configured). Local/LAN always remain present.
    var pairingTargets: [PairingTarget] {
        guard let urls else { return [] }
        // C25: loopback is never a pairing target — Android can't reach it.
        var targets: [PairingTarget] = []
        for e in urls.lan where !hiddenLANBaseURLs.contains(e.baseUrl) {
            targets.append(PairingTarget(scope: .lan, label: "LAN · \(e.baseUrl)", baseUrl: e.baseUrl, wsUrl: e.wsUrl))
        }
        if urls.public.enabled {
            targets.append(PairingTarget(scope: .public, label: "Public · \(urls.public.baseUrl)",
                                         baseUrl: urls.public.baseUrl, wsUrl: urls.public.wsUrl))
        }
        return targets
    }

    /// C23 v3 unified connection payload for the QR code / copy-JSON. It always
    /// includes ALL available candidates (every LAN endpoint + the Public
    /// endpoint when configured) so the client can auto-select — there is no
    /// LAN-only vs LAN+Public mode anymore. Carries the server's connection
    /// config revision so paired clients can detect later URL changes without
    /// rescanning. Loopback/local is never included. Token redacted when asked.
    func pairingPayloadV3(redacted: Bool) -> String {
        // LAN and Public are independent: LAN candidates always go in (when the
        // server is bound to a LAN address); Public is an optional extra.
        let lan = pairingTargets
            .filter { $0.scope == .lan }
            .map { ConnectionCandidate(kind: "lan", baseUrl: $0.baseUrl, wsUrl: $0.wsUrl) }
        let pub = pairingTargets.first { $0.scope == .public }
            .map { ConnectionCandidate(kind: "public", baseUrl: $0.baseUrl, wsUrl: $0.wsUrl) }
        return unifiedConnectionPayload(
            lan: lan,
            publicCandidate: pub,
            token: token,
            serverName: Host.current().localizedName ?? "micaGO Server",
            configRevision: urls?.connectionRevision ?? "",
            redacted: redacted
        )
    }

    /// Unified connection payload encoded into the QR code (v3).
    var pairingPayload: String { pairingPayloadV3(redacted: false) }

    /// Same payload with the token redacted — safe to show/copy.
    var pairingPayloadRedacted: String { pairingPayloadV3(redacted: true) }

    /// Quick capability flags for the Create Connection status line.
    var hasLanCandidate: Bool { pairingTargets.contains { $0.scope == .lan } }
    var hasPublicCandidate: Bool { pairingTargets.contains { $0.scope == .public } }

    /// LAN endpoints that should appear in user-facing summaries (Dashboard) and
    /// be offered for pairing — the user's hidden VPN/virtual endpoints are
    /// excluded. The full list (with hide/unhide/reset) lives in Connections.
    var visibleLANEndpoints: [ConnectionEndpoint] {
        (urls?.lan ?? []).filter { !hiddenLANBaseURLs.contains($0.baseUrl) }
    }

    // MARK: - Hidden LAN endpoints (pairing filter only)

    func isLANHidden(_ baseUrl: String) -> Bool { hiddenLANBaseURLs.contains(baseUrl) }

    func setLANHidden(_ baseUrl: String, hidden: Bool) {
        if hidden { hiddenLANBaseURLs.insert(baseUrl) } else { hiddenLANBaseURLs.remove(baseUrl) }
        persistHiddenLAN()
    }

    func resetHiddenLANEndpoints() {
        hiddenLANBaseURLs.removeAll()
        persistHiddenLAN()
    }

    private func persistHiddenLAN() {
        UserDefaults.standard.set(Array(hiddenLANBaseURLs), forKey: "hiddenLANEndpoints")
    }

    func reloadConfig() {
        config = ConfigReader.read()
        if config == nil {
            lastError = "Could not read \(ConfigReader.configPath). Start the server once to generate it."
        } else if lastError?.contains(ConfigReader.configPath) == true {
            lastError = nil
        }
    }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: self?.pollInterval ?? 3_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        startupRefreshTask?.cancel()
        startupRefreshTask = nil
    }

    /// The backend can create or migrate config during start(), after the app's
    /// initial reload already ran. Immediately reload config and poll briefly so
    /// Dashboard/Connections get LAN URLs as soon as the server answers.
    func refreshAfterBackendStart() {
        startupRefreshTask?.cancel()
        startupRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<16 {
                self.reloadConfig()
                await self.refresh()
                if self.reachable, self.authValid, self.urls != nil {
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func refresh() async {
        if config == nil {
            reloadConfig()
        }
        guard let baseURL else {
            reachable = false
            authValid = false
            status = nil
            devices = []
            activeConnections = []
            urls = nil
            return
        }
        let client = APIClient(baseURL: baseURL, token: token)

        let isUp = await client.health()
        reachable = isUp
        guard isUp else {
            status = nil
            devices = []
            activeConnections = []
            authValid = false
            return
        }

        authValid = await client.checkAuth()
        guard authValid else {
            lastError = "Server is up but the token was rejected. Check \(ConfigReader.configPath)."
            return
        }

        // Each fetch has INDEPENDENT error handling so one failing call never
        // blocks the others. Previously status/devices/urls shared one do/catch,
        // so a status or devices error silently stopped LAN/Public endpoint
        // discovery — and only the explicit Save path (which calls urls directly)
        // refreshed it. Endpoint discovery now always runs when the server is
        // up + authed, exactly like a Save does.
        var pollError: String?
        do { status = try await client.status() } catch { pollError = error.localizedDescription }
        do { activeConnections = try await client.activeConnections() } catch { pollError = error.localizedDescription }
        do { devices = try await client.devices() } catch { pollError = error.localizedDescription }
        do {
            let fetched = try await client.serverURLs()
            applyURLs(fetched)
        } catch {
            pollError = error.localizedDescription
        }
        seedNotificationsForm()
        // C36: the server is reachable + authed here (we passed those guards), so
        // a failed best-effort diagnostic fetch is NOT a user-facing error — record
        // it for Debug and clear any stale actionable banner. This stops a transient
        // poll 500 from showing up as "Server returned HTTP 500" in Sync Control.
        lastPollError = pollError
        lastError = nil
    }

    // Seed the notifications form once from the server status (the
    // service-account path is never returned, so it stays user-entered).
    private func seedNotificationsForm() {
        guard !didSeedNotif, let n = status?.notifications else { return }
        notifEnabled = n.enabled
        notifProvider = n.provider
        notifPreview = n.preview
        fcmEnabled = n.provider == "fcm" || n.implemented.contains("fcm")
        didSeedNotif = true
    }

    private func applyURLs(_ fetched: ServerURLs) {
        urls = fetched

        // Keep the Public URL editor MIRRORING the server's saved value, unless
        // the user is actively editing it. The old "seed once" logic captured an
        // empty value during the brief window before the backend finished
        // loading config, then never re-synced — so a saved Public URL looked
        // cleared/"unknown" after a restart. We only avoid overwriting the field
        // while the user has unsaved edits (input != the value we last seeded).
        let serverPublic = fetched.public.baseUrl
        if publicURLInput == lastSeededPublicURL {
            publicURLInput = serverPublic
            publicVerifyTLS = fetched.public.verifyTls
        }
        lastSeededPublicURL = serverPublic
        // No per-pairing LAN selection to maintain — the unified v3 payload
        // already includes every LAN candidate (C23/C25).
    }

    // MARK: - Public endpoint actions

    func savePublicURL() async {
        guard let baseURL else { return }
        publicBusy = true
        defer { publicBusy = false }
        let client = APIClient(baseURL: baseURL, token: token)
        do {
            let updated = try await client.setPublicURL(
                publicURLInput.trimmingCharacters(in: .whitespacesAndNewlines),
                verifyTLS: publicVerifyTLS,
                preferred: urls?.preferredPairingEndpoint ?? "auto")
            applyURLs(updated)
            publicCheckResult = nil
            lastError = nil
        } catch {
            lastError = "Could not save public URL: \(error.localizedDescription)"
        }
    }

    func validatePublicURL() async {
        guard let baseURL else { return }
        publicBusy = true
        defer { publicBusy = false }
        let client = APIClient(baseURL: baseURL, token: token)
        do {
            publicCheckResult = try await client.checkPublicURL()
            await refresh()
        } catch {
            lastError = "Could not validate public URL: \(error.localizedDescription)"
        }
    }

    func syncContactCache(_ contacts: [ServerContactEntry]) async {
        guard let baseURL else { return }
        var hasher = Hasher()
        hasher.combine(contacts.count)
        for contact in contacts {
            hasher.combine(contact)
        }
        let signature = hasher.finalize()
        if lastSyncedContactCacheSignature == signature { return }
        let client = APIClient(baseURL: baseURL, token: token)
        do {
            try await client.putContactCache(contacts)
            lastSyncedContactCacheSignature = signature
        } catch {
            lastPollError = "contact cache — \(error.localizedDescription)"
        }
    }

    // MARK: - IMCore helper install (C26 / C28)

    /// True when the server reports the advanced message-action helper as usable.
    var helperAvailable: Bool { status?.messageActions?.available ?? false }

    /// The current helper lifecycle state (missing | not_runnable |
    /// unsupported_selectors | ready), or nil before the first status read.
    var helperState: String? { status?.messageActions?.state }

    /// Installs the bundled IMCore helper into `~/.micago/bin` (the location the
    /// backend also scans), forces the running backend to re-scan immediately,
    /// then reloads status — so the card flips to "ready" with no manual restart
    /// or Save (C28). MicaGo owns this — the user never installs imsg/imsgbridge
    /// by hand. When this build ships no helper component, it reports that
    /// honestly instead of faking success.
    func installIMCoreHelper() {
        guard !helperInstalling else { return }
        helperInstalling = true
        helperInstallMessage = nil
        Task { @MainActor in
            defer { helperInstalling = false }
            let path: String
            do {
                path = try IMCoreHelperInstaller.install()
            } catch {
                helperInstallMessage = error.localizedDescription
                return
            }
            guard let baseURL else {
                helperInstallMessage = "Installed the IMCore helper at \(path). Start the server to enable Edit, Unsend, and Delete."
                return
            }
            let client = APIClient(baseURL: baseURL, token: token)
            do {
                // Primary path: ask the running backend to drop its cached probe
                // and re-scan now (no restart, no TTL wait).
                let caps = try await client.refreshMessageActions()
                await refresh()
                helperInstallMessage = installResultMessage(state: caps.state ?? "missing", path: path)
            } catch {
                // Fallback for an older backend without the refresh endpoint:
                // restart it explicitly so the new helper is picked up, then
                // reload status.
                BackendController.shared.restart()
                helperInstallMessage = "Installed the IMCore helper at \(path). Restarting the server to apply…"
                refreshAfterBackendStart()
            }
        }
    }

    /// Force a fresh helper probe on the backend without re-installing, then
    /// reload status. Used by the card's "Re-scan" button.
    func rescanIMCoreHelper() {
        guard !helperInstalling, let baseURL else { return }
        helperInstalling = true
        helperInstallMessage = nil
        Task { @MainActor in
            defer { helperInstalling = false }
            let client = APIClient(baseURL: baseURL, token: token)
            do {
                let caps = try await client.refreshMessageActions()
                await refresh()
                helperInstallMessage = installResultMessage(state: caps.state ?? "missing", path: caps.helper ?? "~/.micago/bin")
            } catch {
                helperInstallMessage = "Could not re-scan: \(error.localizedDescription)"
            }
        }
    }

    /// User-facing line for each post-install helper state.
    private func installResultMessage(state: String, path: String) -> String {
        switch state {
        case "ready":
            return "IMCore helper is ready. Edit, Unsend, and Delete are now available."
        case "not_runnable":
            return "Installed at \(path), but the helper would not run. Check that it is allowed to execute."
        case "unsupported_selectors":
            return "Installed, but this macOS doesn’t expose the required IMCore actions, so Edit/Unsend/Delete stay unavailable."
        default:
            return "Installed the IMCore helper at \(path), but the backend still reports it as unavailable."
        }
    }

    // MARK: - Sync control actions (v0.11.3)

    func loadSyncControl() async {
        guard let baseURL else {
            syncControlError = "Not connected to a server yet."
            return
        }
        let client = APIClient(baseURL: baseURL, token: token)
        // Load each endpoint independently so one failing request doesn't blank
        // the whole page, and so the error names exactly which call failed (the
        // page previously collapsed every failure into one opaque HTTP status).
        var failures: [String] = []
        do { syncRules = try await client.syncRules() }
        catch { failures.append("sync rules — \(error.localizedDescription)") }
        do { syncSettings = try await client.syncSettings() }
        catch { failures.append("sync settings — \(error.localizedDescription)") }
        do { chatsList = try await client.chats() }
        catch { failures.append("chats — \(error.localizedDescription)") }
        // Clear any stale top-of-page error either way: on success there's nothing
        // to show, and on failure the dedicated error card explains exactly which
        // request failed — so a leftover "Server returned HTTP 500" header line
        // (from an earlier poll/action) would only contradict it.
        lastError = nil
        if failures.isEmpty {
            syncControlError = nil
        } else {
            syncControlError = L10n.tr("sync.requestsFailed") + "\n"
                + failures.map { "• \($0)" }.joined(separator: "\n")
        }
    }

    /// Redaction-safe diagnostics for the Sync Control error card (no token, no
    /// message text) — what the Copy diagnostics button puts on the pasteboard.
    var syncControlDiagnosticsText: String {
        var lines = ["micaGO Sync Control diagnostics"]
        lines.append("server: \(baseURL?.absoluteString ?? "—")")
        lines.append("reachable: \(reachable)  authValid: \(authValid)")
        lines.append("loaded: chats \(chatsList.count) · rules \(syncRules?.rules.count ?? 0)")
        lines.append("error: \(syncControlError ?? "none")")
        // Background-poll diagnostic failure (status/connections/devices/urls).
        // Captured here so it isn't swallowed, but never shown as a banner.
        lines.append("pollDiagnostic: \(lastPollError ?? "none")")
        return lines.joined(separator: "\n")
    }

    func saveSyncRule(targetKind: String, targetValue: String, syncMode: String, pushMode: String) async {
        guard let baseURL else { return }
        syncBusy = true
        defer { syncBusy = false }
        let client = APIClient(baseURL: baseURL, token: token)
        do {
            syncRules = try await client.putSyncRule(targetKind: targetKind, targetValue: targetValue,
                                                     syncMode: syncMode, pushMode: pushMode)
            lastError = nil
        } catch {
            lastError = "Save rule: \(error.localizedDescription)"
        }
    }

    func clearSyncRule(targetKind: String, targetValue: String) async {
        guard let baseURL else { return }
        syncBusy = true
        defer { syncBusy = false }
        let client = APIClient(baseURL: baseURL, token: token)
        do {
            syncRules = try await client.deleteSyncRule(targetKind: targetKind, targetValue: targetValue)
            lastError = nil
        } catch {
            lastError = "Clear rule: \(error.localizedDescription)"
        }
    }

    func saveDefaultPolicy(sync: String, push: String) async {
        guard let baseURL else { return }
        syncBusy = true
        defer { syncBusy = false }
        let client = APIClient(baseURL: baseURL, token: token)
        do {
            syncRules = try await client.setSyncPolicy(defaultSync: sync, defaultPush: push)
            lastError = nil
        } catch {
            lastError = "Save policy: \(error.localizedDescription)"
        }
    }

    func saveSyncSettings(_ settings: SyncSettings) async {
        guard let baseURL else { return }
        syncBusy = true
        defer { syncBusy = false }
        let client = APIClient(baseURL: baseURL, token: token)
        do {
            let resp = try await client.putSyncSettings(settings)
            syncSettings = resp.settings
            if let d = resp.diagnostics { lastSyncDiagnostics = d }
            lastError = nil
            await loadSyncControl()
        } catch {
            lastError = "Save sync settings: \(error.localizedDescription)"
        }
    }

    /// The stored rule for a target, if any (exact match; chat by GUID).
    func storedRule(kind: String, value: String) -> SyncRule? {
        syncRules?.rules.first { $0.targetKind == kind && $0.targetValue == value }
    }

    // MARK: - Notifications / FCM config actions (v0.12)

    func saveNotificationsConfig() async {
        guard let baseURL else { return }
        notifBusy = true
        defer { notifBusy = false }
        let client = APIClient(baseURL: baseURL, token: token)
        do {
            let resp = try await client.setNotificationsConfig(
                enabled: notifEnabled,
                provider: fcmEnabled ? "fcm" : "none",
                // C60: honour the user's preview choice — this used to be
                // hardcoded to "sender", which stripped message text from pushes.
                preview: notifPreview,
                fcmEnabled: fcmEnabled, fcmProjectID: fcmProjectID,
                serviceAccountPath: serviceAccountPath,
                googleServicesPath: googleServicesPath,
                publicURLSync: firestoreURLSync)
            firestoreSyncActive = resp.firestoreSyncEnabled
            let fcmReady = resp.implemented.contains("fcm")
            notifResult = "Saved. FCM \(fcmReady ? "configured" : (fcmEnabled ? "config invalid" : "off"))."
            await refresh()
            lastError = nil
        } catch {
            notifResult = "Save failed: \(error.localizedDescription)"
        }
    }

    func clearNotificationsConfig() async {
        notifProvider = "none"
        notifEnabled = false
        fcmEnabled = false
        serviceAccountPath = ""
        googleServicesPath = ""
        fcmProjectID = ""
        firestoreURLSync = false
        await saveNotificationsConfig()
        notifResult = "Firebase configuration cleared."
    }

    func testAllPushDevices() async {
        guard let baseURL else { return }
        notifBusy = true
        defer { notifBusy = false }
        let client = APIClient(baseURL: baseURL, token: token)
        notifResult = await client.testNotifications()
        devices = (try? await client.devices()) ?? devices
    }

    /// C21u: remove a stale/historical paired device, then refresh the list.
    func deleteDevice(deviceID: String) async {
        guard let baseURL else { return }
        let client = APIClient(baseURL: baseURL, token: token)
        do {
            try await client.deleteDevice(deviceID: deviceID)
            devices.removeAll { $0.id == deviceID }
            devices = (try? await client.devices()) ?? devices
        } catch {
            notifResult = "Could not remove device: \(error.localizedDescription)"
        }
    }
}

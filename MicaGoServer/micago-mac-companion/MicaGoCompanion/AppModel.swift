import Foundation
import Combine

/// Companion 的控制状态与后台轮询。
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var config: MicaConfig?
    @Published var reachable = false
    /// False also covers checks that could not complete; it does not imply 401.
    @Published var authValid = false
    @Published var status: ServerStatus?
    @Published var devices: [DeviceInfo] = []
    @Published var activeConnections: [ActiveConnectionInfo] = []
    @Published var lastError: String?
    /// 后台诊断请求的错误仅供调试，不作为操作失败横幅。
    @Published var lastPollError: String?
    @Published var developerModeEnabled: Bool {
        didSet { UserDefaults.standard.set(developerModeEnabled, forKey: "developerModeEnabled") }
    }

    // Connection endpoints
    @Published var urls: ServerURLs?
    @Published var publicURLInput: String = ""
    @Published var publicCheckResult: PublicURLCheckResult?
    @Published var publicBusy = false

    @Published var helperInstalling = false
    @Published var helperInstallMessage: String?


    /// 配对地址的隐藏偏好同步给后端，不改变监听接口。
    @Published var hiddenLANBaseURLs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "hiddenLANEndpoints") ?? [])

    private var pollTask: Task<Void, Never>?
    private var startupRefreshTask: Task<Void, Never>?
    private var refreshing = false
    private let pollInterval: UInt64 = 3 * 1_000_000_000 // 3s
    // 上次回填值用于识别未保存的编辑。
    private var lastSeededPublicURL = ""

    init() {
        developerModeEnabled = UserDefaults.standard.bool(forKey: "developerModeEnabled")
        reloadConfig()
    }

    // Notifications / FCM config
    @Published var notifEnabled = false
    @Published var notifPreview = "sender_and_text"
    @Published var fcmEnabled = false
    @Published var fcmProjectID = ""
    @Published var serviceAccountPath = ""
    @Published var googleServicesPath = ""
    @Published var firestoreURLSync = false
    @Published var notifBusy = false
    @Published var notifResult: String?
    @Published var firestoreSyncActive = false
    private var lastSeededNotifications: NotificationFormValues?

    // Sync control
    @Published var syncRules: SyncRulesResponse?
    let chatPreferences = ChatPreferenceStore()
    @Published var chatsList: [ChatSummary] = []
    @Published var syncBusy = false
    @Published var syncSettings: SyncSettings = .defaults
    /// Non-nil when `loadSyncControl` failed; drives the Sync Control error card
    /// (Retry + Copy diagnostics) instead of a bare inline HTTP-status line.
    @Published var syncControlError: String?

    // Live sync monitor
    @Published var syncNowBusy = false
    @Published var lastSyncDiagnostics: SyncDiagnostics?
    private var lastSyncedContactCacheSignature: Int?

    /// Prefer the newest completed pass so manual snapshots cannot freeze the
    /// monitor once background polling has newer results.
    var syncDiagnostics: SyncDiagnostics? {
        SyncDiagnostics.latest(live: status?.sync.diagnostics, manual: lastSyncDiagnostics)
    }

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
        guard let d = syncDiagnostics else { return L10n.localized( "No sync diagnostics yet.") }
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
        totalTriggers: \(d.pendingTriggerCount ?? 0)  lockRetries: \(d.lockRetryCount ?? 0)
        pendingSends: \(d.pendingSendsCount ?? 0)  lateMatchedSends: \(d.lateMatchedSendsCount ?? 0)
        lastEvent: \(d.lastEmittedEventType ?? "—")  chat: \(d.lastEmittedChatGuid ?? "—")
        lastError: \(d.lastSyncError ?? "—")
        """
    }

    var baseURL: URL? {
        guard let config else { return nil }
        return ConfigReader.baseURL(for: config, launchedAddress: BackendController.shared.launchedBindAddress)
    }

    var token: String { config?.token ?? "" }

    /// v4 配对邀请包含可见 LAN 地址、可选公网地址和连接配置版本。
    @Published var pairingCode = ""
    @Published var pairingExpiresAt: Int64 = 0
    @Published var pairingFingerprint = ""
    @Published var pairingState = "idle"
    private var creatingPairingCode = false

    func refreshPairingCode() async {
        guard !creatingPairingCode, let baseURL else { return }
        creatingPairingCode = true
        defer { creatingPairingCode = false }
        do {
            let invitation = try await APIClient(baseURL: baseURL, token: token).createPairingCode()
            pairingCode = invitation.pairingCode
            pairingExpiresAt = invitation.expiresAt
            pairingFingerprint = invitation.tlsFingerprint
            pairingState = "active"
        } catch { lastError = error.localizedDescription }
    }

    private func refreshPairingStatus(client: APIClient) async {
        guard !pairingCode.isEmpty, pairingState == "active" else { return }
        let code = pairingCode
        if let state = try? await client.pairingStatus(code: code),
           code == pairingCode, ["active", "used", "expired", "invalidated"].contains(state) {
            pairingState = state
        }
    }
    /// Single-use secure invitation encoded into the QR code.
    var pairingPayload: String {
        guard pairingState == "active", !pairingCode.isEmpty,
              pairingExpiresAt > Int64(Date().timeIntervalSince1970 * 1000) else { return "{}" }
        let lan = visibleLANEndpoints.map {
            ConnectionCandidate(kind: "lan", baseUrl: $0.baseUrl, wsUrl: $0.wsUrl)
        }
        let publicCandidate = urls.flatMap { urls in
            urls.public.enabled
                ? ConnectionCandidate(kind: "public", baseUrl: urls.public.baseUrl, wsUrl: urls.public.wsUrl)
                : nil
        }
        return unifiedConnectionPayload(
            lan: lan,
            publicCandidate: publicCandidate,
            pairingCode: pairingCode,
            serverName: Host.current().localizedName ?? "micaGO Server",
            configRevision: urls?.connectionRevision ?? "",
            tlsFingerprint: pairingFingerprint,
            expiresAt: pairingExpiresAt
        )
    }

    var hasLanCandidate: Bool { !visibleLANEndpoints.isEmpty }
    var hasPublicCandidate: Bool { urls?.public.enabled == true }

    /// LAN endpoints that should appear in user-facing summaries (Dashboard) and
    /// be offered for pairing — the user's hidden VPN/virtual endpoints are
    /// excluded. The full list (with hide/unhide/reset) lives in Connections.
    var visibleLANEndpoints: [ConnectionEndpoint] {
        (urls?.lan ?? []).filter { !hiddenLANBaseURLs.contains($0.baseUrl) }
    }

    // MARK: - Hidden LAN endpoints

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
        Task { await refresh() }
    }

    func reloadConfig() {
        config = ConfigReader.read()
        if config == nil {
            lastError = L10n.localized( "Could not read \(ConfigReader.configPath). Start the server once to create it.")
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

    /// 等待后端完成配置创建或迁移，并刷新连接地址。
    func refreshAfterBackendStart() {
        startupRefreshTask?.cancel()
        startupRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<16 {
                guard !Task.isCancelled else { return }
                await self.refresh()
                if self.reachable, self.authValid, self.urls != nil {
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        reloadConfig()
        guard let baseURL else {
            reachable = false
            authValid = false
            clearServerSnapshot()
            return
        }
        var client = APIClient(baseURL: baseURL, token: token)
        do {
            do {
                try await client.checkAuth()
            } catch let error as APIError {
                // A backend upgrade may rotate credentials while this request
                // is in flight. Retry once only if the file actually changed.
                guard case .status(401, _) = error,
                      let latest = ConfigReader.read(),
                      let latestURL = ConfigReader.baseURL(for: latest, launchedAddress: BackendController.shared.launchedBindAddress),
                      latest.token != client.token || latestURL != client.baseURL else { throw error }
                config = latest
                client = APIClient(baseURL: latestURL, token: latest.token)
                try await client.checkAuth()
            }
            reachable = true
            authValid = true
        } catch {
            // An HTTP error proves an endpoint answered. A transport/decoding
            // failure cannot establish that its credentials were rejected.
            guard !Task.isCancelled else { return }
            reachable = error is APIError
            authValid = false
            clearServerSnapshot()
            lastError = error.localizedDescription
            return
        }
        if pairingCode.isEmpty && pairingState == "idle" {
            await refreshPairingCode()
        } else {
            await refreshPairingStatus(client: client)
        }
        await chatPreferences.sync(client: client)

        // 各接口独立处理错误，避免单次失败阻断地址发现。
        var pollError: String?
        do { status = try await client.status() } catch { pollError = error.localizedDescription }
        do { activeConnections = try await client.activeConnections() } catch { pollError = error.localizedDescription }
        do { devices = try await client.devices() } catch { pollError = error.localizedDescription }
        do {
            var fetched = try await client.serverURLs()
            // Preserve hidden interfaces when upgrading from HTTP to TLS.
            var migratedHidden = hiddenLANBaseURLs
            for endpoint in fetched.lan {
                guard var legacy = URLComponents(string: endpoint.baseUrl),
                      legacy.scheme == "https", let port = legacy.port, port > 1 else { continue }
                legacy.scheme = "http"
                legacy.port = port - 1
                if let oldURL = legacy.string, migratedHidden.remove(oldURL) != nil {
                    migratedHidden.insert(endpoint.baseUrl)
                }
            }
            if migratedHidden != hiddenLANBaseURLs {
                hiddenLANBaseURLs = migratedHidden
                UserDefaults.standard.set(Array(migratedHidden), forKey: "hiddenLANEndpoints")
            }
            let reportedHidden = Set(fetched.lan.filter { $0.hidden == true }.map(\.baseUrl))
            if fetched.lan.contains(where: { $0.hidden == nil }) || reportedHidden != hiddenLANBaseURLs.intersection(Set(fetched.lan.map(\.baseUrl))) {
                // Older backends keep the local pairing filter until upgraded.
                if let updated = try? await client.setLANVisibility(hiddenLANBaseURLs) { fetched = updated }
            }
            applyURLs(fetched)
        } catch {
            pollError = error.localizedDescription
        }
        seedNotificationsForm()
        // 后台诊断错误只写入调试字段。
        lastPollError = pollError
        lastError = nil
    }

    private func clearServerSnapshot() {
        status = nil
        devices = []
        activeConnections = []
        urls = nil
        lastSyncDiagnostics = nil
    }

    // Mirror server changes without overwriting unsaved edits. File paths are
    // never returned by status and remain user-entered.
    private func seedNotificationsForm() {
        guard let n = status?.notifications else { return }
        firestoreSyncActive = (n.publicUrlSync ?? false) && n.implemented.contains("fcm")
        let server = NotificationFormValues(enabled: n.enabled, preview: n.preview,
            fcmEnabled: n.fcmEnabled ?? (n.provider == "fcm"),
            projectID: n.fcmProjectId ?? "", publicURLSync: n.publicUrlSync ?? false)
        let current = NotificationFormValues(enabled: notifEnabled, preview: notifPreview,
            fcmEnabled: fcmEnabled, projectID: fcmProjectID, publicURLSync: firestoreURLSync)
        let merged = current.merging(server: server, previousServer: lastSeededNotifications)
        if merged != current {
            notifEnabled = merged.enabled
            notifPreview = merged.preview
            fcmEnabled = merged.fcmEnabled
            fcmProjectID = merged.projectID
            firestoreURLSync = merged.publicURLSync
        }
        lastSeededNotifications = server
    }

    private func applyURLs(_ fetched: ServerURLs) {
        urls = fetched

        // 仅在没有未保存编辑时回填公网地址。
        let serverPublic = fetched.public.baseUrl
        if publicURLInput == lastSeededPublicURL {
            publicURLInput = serverPublic
        }
        lastSeededPublicURL = serverPublic
        // No per-pairing LAN selection to maintain — the unified v4 payload
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
                verifyTLS: true,
                preferred: urls?.preferredPairingEndpoint ?? "auto")
            applyURLs(updated)
            publicCheckResult = nil
            lastError = nil
        } catch {
            lastError = L10n.localized( "Could not save public URL: \(error.localizedDescription)")
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
            lastError = L10n.localized( "Could not validate public URL: \(error.localizedDescription)")
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
                helperInstallMessage = L10n.localized( "Installed the IMCore helper at \(path). Start the server to turn on Edit, Unsend, and Delete.")
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
                helperInstallMessage = L10n.localized( "Installed the IMCore helper at \(path). Restarting the server to apply…")
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
                helperInstallMessage = L10n.localized( "Could not re-scan: \(error.localizedDescription)")
            }
        }
    }

    /// C79: removes the installed helper and re-scans, so the card immediately
    /// reflects "not installed". Needed on macOS 26+, where the helper can never
    /// work and users who installed it earlier had no way to remove it.
    func uninstallIMCoreHelper() {
        guard !helperInstalling else { return }
        helperInstalling = true
        helperInstallMessage = nil
        Task { @MainActor in
            defer { helperInstalling = false }
            let removed: Bool
            do {
                removed = try IMCoreHelperInstaller.uninstall()
            } catch {
                helperInstallMessage = error.localizedDescription
                return
            }
            guard removed else {
                helperInstallMessage = L10n.localized( "No IMCore helper was installed.")
                return
            }
            guard let baseURL else {
                helperInstallMessage = L10n.localized( "Removed the IMCore helper.")
                return
            }
            let client = APIClient(baseURL: baseURL, token: token)
            do {
                _ = try await client.refreshMessageActions()
                await refresh()
                helperInstallMessage = L10n.localized( "Removed the IMCore helper.")
            } catch {
                helperInstallMessage = L10n.localized( "Removed the IMCore helper. Restart the server to refresh its status.")
            }
        }
    }

    /// True when a helper binary is present in `~/.micago/bin`.
    var helperInstalledOnDisk: Bool { IMCoreHelperInstaller.isInstalled }

    /// User-facing line for each post-install helper state.
    private func installResultMessage(state: String, path: String) -> String {
        switch state {
        case "ready":
            return L10n.localized( "The IMCore helper is ready. Edit, Unsend, and Delete are available.")
        case "not_runnable":
            return L10n.localized( "Installed at \(path), but the helper won\u{2019}t run. Check that macOS allows it to run.")
        case "unsupported_selectors":
            return L10n.localized( "Installed, but this version of macOS doesn’t offer the IMCore actions, so Edit, Unsend, and Delete stay off.")
        default:
            return L10n.localized( "Installed the IMCore helper at \(path), but the backend still reports it as unavailable.")
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
            lastError = L10n.localized( "Save rule: \(error.localizedDescription)")
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
            lastError = L10n.localized( "Clear rule: \(error.localizedDescription)")
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
            lastError = L10n.localized( "Save policy: \(error.localizedDescription)")
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
            lastError = L10n.localized( "Save sync settings: \(error.localizedDescription)")
        }
    }

    /// The stored rule for a target, if any (exact match; chat by GUID).
    func storedRule(kind: String, value: String) -> SyncRule? {
        syncRules?.rules.first { $0.targetKind == kind && $0.targetValue == value }
    }

    // MARK: - Notifications / FCM config actions (v0.12)

    @discardableResult
    func saveNotificationsConfig(clearFirebaseConfig: Bool = false) async -> Bool {
        guard let baseURL else { return false }
        notifBusy = true
        defer { notifBusy = false }
        let submittedServiceAccount = serviceAccountPath
        let submittedGoogleServices = googleServicesPath
        let client = APIClient(baseURL: baseURL, token: token)
        do {
            let resp = try await client.setNotificationsConfig(
                enabled: notifEnabled,
                provider: fcmEnabled ? "fcm" : "none",
                preview: notifPreview,
                fcmEnabled: fcmEnabled, fcmProjectID: fcmProjectID,
                serviceAccountPath: submittedServiceAccount,
                googleServicesPath: submittedGoogleServices,
                publicURLSync: firestoreURLSync,
                clearFirebaseConfig: clearFirebaseConfig)
            // Empty editors preserve saved backend references. Keep newer,
            // unsaved selections made while the request was in flight.
            if serviceAccountPath == submittedServiceAccount { serviceAccountPath = "" }
            if googleServicesPath == submittedGoogleServices { googleServicesPath = "" }
            firestoreSyncActive = resp.firestoreSyncEnabled
            let fcmReady = resp.implemented.contains("fcm")
            notifResult = "Saved. FCM \(fcmReady ? "configured" : (fcmEnabled ? "config invalid" : "off"))."
            await refresh()
            lastError = nil
            return true
        } catch {
            notifResult = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    func clearNotificationsConfig() async {
        guard await saveNotificationsConfig(clearFirebaseConfig: true) else { return }
        notifEnabled = false
        fcmEnabled = false
        serviceAccountPath = ""
        googleServicesPath = ""
        fcmProjectID = ""
        firestoreURLSync = false
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

    /// Revoke device credentials and active sockets, then refresh the list.
    func deleteDevice(deviceID: String) async {
        guard let baseURL else { return }
        let client = APIClient(baseURL: baseURL, token: token)
        do {
            try await client.deleteDevice(deviceID: deviceID)
            devices.removeAll { $0.id == deviceID }
            devices = (try? await client.devices()) ?? devices
        } catch {
            notifResult = "Could not revoke device: \(error.localizedDescription)"
        }
    }
}

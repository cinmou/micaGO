import Foundation

/// 本机控制 API 客户端。
struct APIClient {
    var baseURL: URL
    var token: String
    var session: URLSession = Self.sharedSession

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) -> URLRequest {
        var url = baseURL
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component)) // percent-encodes each segment
        }
        if !query.isEmpty, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.queryItems = query
            if let withQuery = comps.url { url = withQuery }
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        // 大型 relay.db 查询可能耗时数秒。
        req.timeoutInterval = 20
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func jsonRequest(_ path: String, method: String, body: [String: Any]) throws -> URLRequest {
        request(path, method: method, body: try JSONSerialization.data(withJSONObject: body))
    }

    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
            throw APIError.status(http.statusCode, message: message)
        }
        return data
    }

    private func decode<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        try JSONDecoder().decode(type, from: await data(for: request))
    }

    private struct CheckResponse: Decodable { let ok: Bool }

    /// Preserve HTTP failures and transport errors so callers do not confuse an
    /// interrupted request or unavailable authorization service with HTTP 401.
    func checkAuth() async throws {
        let response = try await decode(request("api/auth/check", method: "POST"), as: CheckResponse.self)
        guard response.ok else { throw APIError.badResponse }
    }

    func status() async throws -> ServerStatus {
        return try await decode(request("api/server/status"), as: ServerStatus.self)
    }

    func chatPreferences() async throws -> ChatPreferencesResponse {
        return try await decode(request("api/chat-preferences"), as: ChatPreferencesResponse.self)
    }

    func patchChatPreferences(_ mutation: ChatPreferenceMutation) async throws -> ChatPreferencesResponse {
        let req = request("api/chat-preferences", method: "PATCH", body: try JSONEncoder().encode(mutation))
        return try await decode(req, as: ChatPreferencesResponse.self)
    }

    func devices() async throws -> [DeviceInfo] {
        return try await decode(request("api/devices"), as: DeviceListResponse.self).data
    }

    func activeConnections() async throws -> [ActiveConnectionInfo] {
        return try await decode(request("api/server/connections"), as: ActiveConnectionListResponse.self).data
    }

    /// 安装 helper 后刷新后端能力探测缓存。
    @discardableResult
    func refreshMessageActions() async throws -> MessageActionsStatus {
        return try await decode(request("api/messages/actions/refresh", method: "POST"), as: MessageActionsStatus.self)
    }

    // MARK: - Connection endpoints

    func serverURLs() async throws -> ServerURLs {
        return try await decode(request("api/server/urls"), as: ServerURLs.self)
    }

    func setLANVisibility(_ hiddenBaseURLs: Set<String>) async throws -> ServerURLs {
        let req = try jsonRequest("api/server/lan-visibility", method: "PUT", body: ["hiddenBaseUrls": hiddenBaseURLs.sorted()])
        return try await decode(req, as: ServerURLs.self)
    }

    /// Sets (or clears, with an empty string) the optional public endpoint.
    @discardableResult
    func setPublicURL(_ publicBaseURL: String, verifyTLS: Bool, preferred: String) async throws -> ServerURLs {
        let req = try jsonRequest("api/server/public-url", method: "POST", body: [
            "publicBaseUrl": publicBaseURL,
            "verifyTls": verifyTLS,
            "preferredPairingEndpoint": preferred,
        ])
        return try await decode(req, as: ServerURLs.self)
    }

    func checkPublicURL() async throws -> PublicURLCheckResult {
        return try await decode(request("api/server/public-url/check", method: "POST"), as: PublicURLCheckResult.self)
    }

    // MARK: - Sync

    /// Triggers an immediate server sync and returns the resulting diagnostics.
    @discardableResult
    func runSyncNow() async throws -> SyncDiagnostics {
        return try await decode(request("api/sync/now", method: "POST"), as: SyncNowResponse.self).diagnostics
    }

    func syncSettings() async throws -> SyncSettings {
        return try await decode(request("api/sync/settings"), as: SyncSettings.self)
    }

    @discardableResult
    func putSyncSettings(_ settings: SyncSettings) async throws -> SyncSettingsResponse {
        let req = request("api/sync/settings", method: "PUT", body: try JSONEncoder().encode(settings))
        return try await decode(req, as: SyncSettingsResponse.self)
    }

    // MARK: - Sync control

    func syncRules() async throws -> SyncRulesResponse {
        return try await decode(request("api/sync/rules"), as: SyncRulesResponse.self)
    }

    @discardableResult
    func putSyncRule(targetKind: String, targetValue: String, syncMode: String, pushMode: String) async throws -> SyncRulesResponse {
        let req = try jsonRequest("api/sync/rules", method: "PUT", body: [
            "targetKind": targetKind,
            "targetValue": targetValue,
            "syncMode": syncMode,
            "pushMode": pushMode,
        ])
        return try await decode(req, as: SyncRulesResponse.self)
    }

    @discardableResult
    func deleteSyncRule(targetKind: String, targetValue: String) async throws -> SyncRulesResponse {
        return try await decode(request("api/sync/rules/\(targetKind)/\(targetValue)", method: "DELETE"), as: SyncRulesResponse.self)
    }

    @discardableResult
    func setSyncPolicy(defaultSync: String, defaultPush: String) async throws -> SyncRulesResponse {
        let req = try jsonRequest("api/sync/policy", method: "PUT", body: [
            "defaultSyncPolicy": defaultSync,
            "defaultPushPolicy": defaultPush,
        ])
        return try await decode(req, as: SyncRulesResponse.self)
    }

    /// Message Inspector (debug). Structural filters run server-side in SQL;
    /// query/type/attachment refinement and grouping are applied on the page.
    func debugRecentMessages(
        q: String = "",
        chatGuid: String = "",
        sender: String = "",
        direction: String = "",
        type: String = "",
        hasAttachments: String = "",
        groupBy: String = "",
        limit: Int = 100,
        offset: Int = 0
    ) async throws -> DebugRecentResponse {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
        ]
        func add(_ name: String, _ value: String) {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { items.append(URLQueryItem(name: name, value: v)) }
        }
        add("q", q)
        add("chatGuid", chatGuid)
        add("sender", sender)
        add("direction", direction)
        add("type", type)
        add("hasAttachments", hasAttachments)
        add("groupBy", groupBy)

        return try await decode(request("api/debug/recent-messages", query: items), as: DebugRecentResponse.self)
    }

    /// Chats (all services, including archived) so users can target rules.
    func chats() async throws -> [ChatSummary] {
        return try await decode(request(
            "api/chats",
            query: [URLQueryItem(name: "service", value: "all"),
                    URLQueryItem(name: "withArchived", value: "true"),
                    URLQueryItem(name: "limit", value: "500")]), as: ChatListResponse.self).data
    }

    // MARK: - Notifications / FCM config

    @discardableResult
    func setNotificationsConfig(enabled: Bool, provider: String, preview: String,
                                fcmEnabled: Bool, fcmProjectID: String,
                                serviceAccountPath: String, googleServicesPath: String,
                                publicURLSync: Bool, clearFirebaseConfig: Bool = false) async throws -> NotificationsConfigResponse {
        let req = try jsonRequest("api/server/notifications", method: "POST", body: [
            "enabled": enabled,
            "provider": provider,
            "preview": preview,
            "fcmEnabled": fcmEnabled,
            "fcmProjectId": fcmProjectID,
            "serviceAccountPath": serviceAccountPath,
            "googleServicesPath": googleServicesPath,
            "publicUrlSync": publicURLSync,
            "clearFirebaseConfig": clearFirebaseConfig,
        ])
        return try await decode(req, as: NotificationsConfigResponse.self)
    }

    /// Sends a real test push through the server's current notification setup.
    func testNotifications() async -> String {
        do {
            let envelope = try await decode(request("api/server/notifications/test", method: "POST"), as: TestNotificationsEnvelope.self)
            let result = envelope.data
            if result.failed == 0 {
                return "Test push sent to \(result.sent) device\(result.sent == 1 ? "" : "s")."
            }
            let first = result.failures?.first ?? "Unknown error"
            return "Sent \(result.sent), failed \(result.failed). \(first)"
        } catch is URLError {
            return "Test push failed: could not reach server."
        } catch {
            return "Test push failed: \(error.localizedDescription)"
        }
    }

    func putContactCache(_ contacts: [ServerContactEntry]) async throws {
        let rows = contacts.map { ["name": $0.name, "addresses": $0.addresses] as [String: Any] }
        let req = try jsonRequest("api/server/contacts/cache", method: "PUT", body: ["contacts": rows])
        _ = try await data(for: req)
    }

    /// A short-lived invitation returned by the local control API.
    struct PairingInvitation: Decodable {
        let pairingCode: String
        let expiresAt: Int64
        let tlsFingerprint: String
    }
    func createPairingCode() async throws -> PairingInvitation {
        try await decode(request("api/pairing/create", method: "POST"), as: PairingInvitation.self)
    }

    struct PairingStatus: Decodable { let state: String }
    func pairingStatus(code: String) async throws -> String {
        let req = try jsonRequest("api/pairing/status", method: "POST", body: ["pairingCode": code])
        return try await decode(req, as: PairingStatus.self).state
    }

    func deleteDevice(deviceID: String) async throws {
        let req = request("api/devices/\(deviceID)", method: "DELETE")
        _ = try await data(for: req)
    }

    // MARK: - Test contact (offline loopback)

    /// GET /api/test-contact — whether the offline test contact is on.
    func testContactInfo() async throws -> TestContactInfo {
        return try await decode(request("api/test-contact"), as: TestContactInfo.self)
    }

    /// PUT /api/test-contact — turn the offline test contact on or off.
    func setTestContact(enabled: Bool) async throws -> TestContactInfo {
        let req = try jsonRequest("api/test-contact", method: "PUT", body: ["enabled": enabled])
        _ = try await data(for: req)
        // PUT returns {enabled}; re-read for the full info shape.
        return try await testContactInfo()
    }

    /// POST /api/test-contact/inbound — inject a message *from* the test contact,
    /// which pushes to the client like a received iMessage.
    func sendTestInbound(_ text: String) async throws {
        let req = try jsonRequest("api/test-contact/inbound", method: "POST", body: ["text": text])
        _ = try await data(for: req)
    }

    /// GET /api/chats/{guid}/messages — the conversation, newest first.
    func chatMessages(guid: String, limit: Int = 200) async throws -> [RecentMessage] {
        let req = request("api/chats/\(guid)/messages", query: [URLQueryItem(name: "limit", value: "\(limit)")])
        return try await decode(req, as: RecentMessagesResponse.self).data
    }
}

struct TestContactInfo: Codable {
    var available: Bool
    var enabled: Bool
    var handle: String?
    var chatGuid: String?
}

enum APIError: LocalizedError {
    case badResponse
    case status(Int, message: String? = nil)

    var errorDescription: String? {
        switch self {
        case .badResponse: return L10n.localized( "Unexpected response from the server.")
        case .status(let code, let message):
            if let message, !message.isEmpty { return "HTTP \(code): \(message)" }
            return L10n.localized( "Server returned HTTP \(code).")
        }
    }
}

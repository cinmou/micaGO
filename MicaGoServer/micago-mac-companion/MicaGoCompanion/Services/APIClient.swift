import Foundation

/// Minimal async client for the MicaGoServer local control API. It only calls
/// the read-only / control endpoints the companion needs; it is NOT a chat
/// client.
struct APIClient {
    var baseURL: URL
    var token: String

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = []) -> URLRequest {
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
        // Data loads like `GET /api/chats?limit=500` aggregate per-chat over the
        // whole relay.db; on a large DB that can take a few seconds. A tight
        // timeout here is what surfaced as "chats — The request timed out" even
        // though the server was healthy. Give real headroom (the server is local
        // / LAN, so a genuinely-down server still fails fast with a connection
        // error, not a timeout).
        req.timeoutInterval = 20
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func jsonRequest(_ path: String, method: String, body: [String: Any]) throws -> URLRequest {
        var req = request(path, method: method)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        // Was 4s — too tight for the larger Sync Control loads (see request()).
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }

    /// Liveness check against the unauthenticated health endpoint.
    func health() async -> Bool {
        let req = request("api/health")
        guard let (_, response) = try? await Self.session().data(for: req),
              let http = response as? HTTPURLResponse else {
            return false
        }
        return http.statusCode == 200
    }

    /// Returns true if the configured token is accepted.
    func checkAuth() async -> Bool {
        let req = request("api/auth/check", method: "POST")
        guard let (_, response) = try? await Self.session().data(for: req),
              let http = response as? HTTPURLResponse else {
            return false
        }
        return http.statusCode == 200
    }

    func status() async throws -> ServerStatus {
        let (data, response) = try await Self.session().data(for: request("api/server/status"))
        try Self.validate(response)
        return try JSONDecoder().decode(ServerStatus.self, from: data)
    }

    func devices() async throws -> [DeviceInfo] {
        let (data, response) = try await Self.session().data(for: request("api/devices"))
        try Self.validate(response)
        return try JSONDecoder().decode(DeviceListResponse.self, from: data).data
    }

    func activeConnections() async throws -> [ActiveConnectionInfo] {
        let (data, response) = try await Self.session().data(for: request("api/server/connections"))
        try Self.validate(response)
        return try JSONDecoder().decode(ActiveConnectionListResponse.self, from: data).data
    }

    /// C28: force the backend to drop its cached IMCore-helper probe and re-scan,
    /// returning the fresh capability state. Called right after a helper install.
    @discardableResult
    func refreshMessageActions() async throws -> MessageActionsStatus {
        let (data, response) = try await Self.session().data(for: request("api/messages/actions/refresh", method: "POST"))
        try Self.validate(response)
        return try JSONDecoder().decode(MessageActionsStatus.self, from: data)
    }

    // MARK: - Connection endpoints (v0.11)

    func serverURLs() async throws -> ServerURLs {
        let (data, response) = try await Self.session().data(for: request("api/server/urls"))
        try Self.validate(response)
        return try JSONDecoder().decode(ServerURLs.self, from: data)
    }

    /// Sets (or clears, with an empty string) the optional public endpoint.
    @discardableResult
    func setPublicURL(_ publicBaseURL: String, verifyTLS: Bool, preferred: String) async throws -> ServerURLs {
        var req = request("api/server/public-url", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "publicBaseUrl": publicBaseURL,
            "verifyTls": verifyTLS,
            "preferredPairingEndpoint": preferred,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await Self.session().data(for: req)
        try Self.validate(response)
        return try JSONDecoder().decode(ServerURLs.self, from: data)
    }

    func checkPublicURL() async throws -> PublicURLCheckResult {
        let (data, response) = try await Self.session().data(for: request("api/server/public-url/check", method: "POST"))
        try Self.validate(response)
        return try JSONDecoder().decode(PublicURLCheckResult.self, from: data)
    }

    // MARK: - Sync (C11 debug)

    /// Triggers an immediate server sync and returns the resulting diagnostics.
    @discardableResult
    func runSyncNow() async throws -> SyncDiagnostics {
        let (data, response) = try await Self.session().data(for: request("api/sync/now", method: "POST"))
        try Self.validate(response)
        return try JSONDecoder().decode(SyncNowResponse.self, from: data).diagnostics
    }

    func syncSettings() async throws -> SyncSettings {
        let (data, response) = try await Self.session().data(for: request("api/sync/settings"))
        try Self.validate(response, body: data)
        return try JSONDecoder().decode(SyncSettings.self, from: data)
    }

    @discardableResult
    func putSyncSettings(_ settings: SyncSettings) async throws -> SyncSettingsResponse {
        let data = try JSONEncoder().encode(settings)
        var req = request("api/sync/settings", method: "PUT")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let (body, response) = try await Self.session().data(for: req)
        try Self.validate(response)
        return try JSONDecoder().decode(SyncSettingsResponse.self, from: body)
    }

    // MARK: - Sync control (v0.11.3)

    func syncRules() async throws -> SyncRulesResponse {
        let (data, response) = try await Self.session().data(for: request("api/sync/rules"))
        try Self.validate(response, body: data)
        return try JSONDecoder().decode(SyncRulesResponse.self, from: data)
    }

    @discardableResult
    func putSyncRule(targetKind: String, targetValue: String, syncMode: String, pushMode: String) async throws -> SyncRulesResponse {
        let req = try jsonRequest("api/sync/rules", method: "PUT", body: [
            "targetKind": targetKind,
            "targetValue": targetValue,
            "syncMode": syncMode,
            "pushMode": pushMode,
        ])
        let (data, response) = try await Self.session().data(for: req)
        try Self.validate(response)
        return try JSONDecoder().decode(SyncRulesResponse.self, from: data)
    }

    @discardableResult
    func deleteSyncRule(targetKind: String, targetValue: String) async throws -> SyncRulesResponse {
        let (data, response) = try await Self.session().data(
            for: request("api/sync/rules/\(targetKind)/\(targetValue)", method: "DELETE"))
        try Self.validate(response)
        return try JSONDecoder().decode(SyncRulesResponse.self, from: data)
    }

    @discardableResult
    func setSyncPolicy(defaultSync: String, defaultPush: String) async throws -> SyncRulesResponse {
        let req = try jsonRequest("api/sync/policy", method: "PUT", body: [
            "defaultSyncPolicy": defaultSync,
            "defaultPushPolicy": defaultPush,
        ])
        let (data, response) = try await Self.session().data(for: req)
        try Self.validate(response)
        return try JSONDecoder().decode(SyncRulesResponse.self, from: data)
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

        let (data, response) = try await Self.session().data(for: request("api/debug/recent-messages", query: items))
        try Self.validate(response)
        return try JSONDecoder().decode(DebugRecentResponse.self, from: data)
    }

    /// Chats (all services, including archived) so users can target rules.
    func chats() async throws -> [ChatSummary] {
        let (data, response) = try await Self.session().data(for: request(
            "api/chats",
            query: [URLQueryItem(name: "service", value: "all"),
                    URLQueryItem(name: "withArchived", value: "true"),
                    URLQueryItem(name: "limit", value: "500")]))
        try Self.validate(response, body: data)
        return try JSONDecoder().decode(ChatListResponse.self, from: data).data
    }

    // MARK: - Notifications / FCM config (v0.12)

    @discardableResult
    func setNotificationsConfig(enabled: Bool, provider: String, preview: String,
                                fcmEnabled: Bool, fcmProjectID: String,
                                serviceAccountPath: String, googleServicesPath: String,
                                publicURLSync: Bool) async throws -> NotificationsConfigResponse {
        let req = try jsonRequest("api/server/notifications", method: "POST", body: [
            "enabled": enabled,
            "provider": provider,
            "preview": preview,
            "fcmEnabled": fcmEnabled,
            "fcmProjectId": fcmProjectID,
            "serviceAccountPath": serviceAccountPath,
            "googleServicesPath": googleServicesPath,
            "publicUrlSync": publicURLSync,
        ])
        let (data, response) = try await Self.session().data(for: req)
        // Surface the server's validation message on 4xx (e.g. invalid service account).
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
                throw APIError.message(env.error.message)
            }
            throw APIError.status(http.statusCode)
        }
        return try JSONDecoder().decode(NotificationsConfigResponse.self, from: data)
    }

    /// Sends a real test push through the server's current notification setup.
    func testNotifications() async -> String {
        let req = request("api/server/notifications/test", method: "POST")
        guard let (data, response) = try? await Self.session().data(for: req),
              let http = response as? HTTPURLResponse else {
            return "Test push failed: could not reach server."
        }
        if let env = try? JSONDecoder().decode(TestNotificationsEnvelope.self, from: data) {
            let result = env.data
            if result.failed == 0 {
                return "Test push sent to \(result.sent) device\(result.sent == 1 ? "" : "s")."
            }
            let first = result.failures?.first ?? "Unknown error"
            return "Sent \(result.sent), failed \(result.failed). \(first)"
        }
        if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
            return "Test push failed: \(env.error.message)"
        }
        return "Test push failed: HTTP \(http.statusCode)."
    }

    func putContactCache(_ contacts: [ServerContactEntry]) async throws {
        let rows = contacts.map { ["name": $0.name, "addresses": $0.addresses] as [String: Any] }
        let req = try jsonRequest("api/server/contacts/cache", method: "PUT", body: ["contacts": rows])
        let (data, response) = try await Self.session().data(for: req)
        try Self.validate(response, body: data)
    }

    /// Deletes a paired device record (C21u) — used to prune stale/historical
    /// devices from the list.
    func deleteDevice(deviceID: String) async throws {
        let req = request("api/devices/\(deviceID)", method: "DELETE")
        let (_, response) = try await Self.session().data(for: req)
        try Self.validate(response)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.status(http.statusCode)
        }
    }

    /// Like `validate`, but on a non-2xx it surfaces the server's structured
    /// error message (the `{error:{code,message}}` envelope) so callers can show
    /// *why* the request failed — e.g. "sync settings are not available" —
    /// instead of a bare status code.
    private static func validate(_ response: URLResponse, body data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
               !env.error.message.isEmpty {
                throw APIError.message("HTTP \(http.statusCode): \(env.error.message)")
            }
            throw APIError.status(http.statusCode)
        }
    }

    // MARK: - Test contact (offline loopback)

    /// GET /api/test-contact — whether the offline test contact is on.
    func testContactInfo() async throws -> TestContactInfo {
        let (data, response) = try await Self.session().data(for: request("api/test-contact"))
        try Self.validate(response, body: data)
        return try JSONDecoder().decode(TestContactInfo.self, from: data)
    }

    /// PUT /api/test-contact — turn the offline test contact on or off.
    func setTestContact(enabled: Bool) async throws -> TestContactInfo {
        let req = try jsonRequest("api/test-contact", method: "PUT", body: ["enabled": enabled])
        let (data, response) = try await Self.session().data(for: req)
        try Self.validate(response, body: data)
        // PUT returns {enabled}; re-read for the full info shape.
        _ = data
        return try await testContactInfo()
    }

    /// POST /api/test-contact/inbound — inject a message *from* the test contact,
    /// which pushes to the client like a received iMessage.
    func sendTestInbound(_ text: String) async throws {
        let req = try jsonRequest("api/test-contact/inbound", method: "POST", body: ["text": text])
        let (data, response) = try await Self.session().data(for: req)
        try Self.validate(response, body: data)
    }

    /// GET /api/chats/{guid}/messages — the conversation, newest first.
    func chatMessages(guid: String, limit: Int = 200) async throws -> [RecentMessage] {
        let req = request("api/chats/\(guid)/messages", query: [URLQueryItem(name: "limit", value: "\(limit)")])
        let (data, response) = try await Self.session().data(for: req)
        try Self.validate(response, body: data)
        return try JSONDecoder().decode(RecentMessagesResponse.self, from: data).data
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
    case status(Int)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Unexpected response from the server."
        case .status(let code): return "Server returned HTTP \(code)."
        case .message(let msg): return msg
        }
    }
}

import Foundation

// Codable mirrors of the server's GET /api/server/status payload.
// See MicaGoServer/docs/spec-v0.9.0-client-api-contract.md and
// spec-v0.10.0-mac-companion.md.

struct ServerStatus: Codable {
    var ok: Bool
    var version: String
    var startedAt: Int64
    var uptimeSeconds: Int64
    var address: AddressStatus
    var store: String
    var auth: AuthStatus
    var sync: SyncStatus
    var notifications: NotificationStatus
    var devices: DevicesStatus
    var websocket: WebSocketStatus
    var permissions: PermissionStatus
    // Added by v0.11.x schema probing. Optional so older servers still decode.
    var capabilities: ServerCapabilities?
    // C26: IMCore helper status for the advanced iMessage actions (edit/unsend/
    // delete). Optional so pre-C26 servers still decode (absence → unavailable).
    var messageActions: MessageActionsStatus?
    // C17 backend identity: which binary is actually running. Optional so
    // pre-v0.15 servers still decode — its absence itself means "stale backend".
    var backend: BackendStatus?
}

/// C26: whether the bundled IMCore helper that performs edit / unsend / delete is
/// present and runnable. `available` is the gate; `reason` explains a missing or
/// failing helper. Mirrors the server's `messageActions` status block.
struct MessageActionsStatus: Codable {
    var available: Bool
    /// missing | not_runnable | unsupported_selectors | ready. Optional so a
    /// pre-C28 server (no `state`) still decodes.
    var state: String?
    var edit: Bool
    var retract: Bool
    var delete: Bool
    var helper: String?
    var reason: String?
    var requiresMessages: Bool
    var minimumMacOS: String?
    var platformSupported: Bool?
    var platformWarning: String?
}

/// C17: identity of the running backend binary, from /api/server/status.
struct BackendStatus: Codable {
    var version: String
    var commit: String
    var buildTime: String
    var goVersion: String
    var osArch: String
    var executablePath: String
    var configPath: String
    var relayDbPath: String
    var chatDbPath: String
    var chatDbOpenOptions: String
    var chatDbImmutable: Bool
}

/// C17: live sync settings echoed by the server (backfill mode, service scope).
struct SyncSettingsStatus: Codable {
    var backfillMode: String
    var recentMessagesPerChat: Int
    var includeIMessage: Bool
    var includeSMS: Bool
    var includeRCS: Bool
    var includeUnknown: Bool
    var includeDebugInNormal: Bool
}

struct ServerCapabilities: Codable {
    var schema: SchemaCapabilities
}

struct SchemaCapabilities: Codable {
    var editedMessages: Bool
    var unsentMessages: Bool
    var readStatus: Bool
    var deliveredStatus: Bool
    var sendError: Bool
    var groupActions: Bool
    var attachmentMetadata: Bool
}

struct AddressStatus: Codable {
    var listen: String
    var baseUrl: String
    var websocketUrl: String
    var lan: [String]
}

struct AuthStatus: Codable {
    var enabled: Bool
}

struct SyncStatus: Codable {
    var loopEnabled: Bool
    var intervalSeconds: Int64
    var lastSyncAt: Int64?
    var lastMessageRowId: Int64?
    // C11 live sync monitor. Optional so older servers still decode.
    var diagnostics: SyncDiagnostics?
    // C17: settings the running backend actually loaded.
    var settings: SyncSettingsStatus?
}

/// Envelope for POST /api/sync/now (`{ok, diagnostics}`).
struct SyncNowResponse: Codable {
    var ok: Bool
    var diagnostics: SyncDiagnostics
}

/// C11 live-sync diagnostics surfaced by GET /api/server/status (and the
/// POST /api/sync/now response). No tokens or full message text.
struct SyncDiagnostics: Codable {
    var lastStartedAt: Int64?
    var lastCompletedAt: Int64?
    var lastDurationMillis: Int64?
    var lastTriggerReason: String?
    var lastInsertedMessages: Int?
    var lastSyncedMessages: Int?
    var lastRowsScanned: Int?
    var lastRenderableRows: Int?
    var lastHiddenDebugRows: Int?
    var lastPerChatLimit: Int?
    var lastBackfillMode: String?
    var lastUpdatePassCount: Int?
    var lastUnsentCount: Int?
    var lastScannedMessageRowId: Int64?
    var lastChatDbMtime: Int64?
    var lastWalMtime: Int64?
    var lastShmMtime: Int64?
    var lastSyncError: String?
    var pendingSendsCount: Int?
    var pendingTriggerCount: Int?
    var lockRetryCount: Int?
    var lateMatchedSendsCount: Int?
    var lastEmittedEventType: String?
    var lastEmittedChatGuid: String?
}

struct NotificationStatus: Codable {
    var enabled: Bool
    var provider: String
    var preview: String
    var providers: [String]
    var implemented: [String]
    var stub: [String]
    var fcmServiceAccountConfigured: Bool?
    var fcmClientConfigured: Bool?
}

struct DevicesStatus: Codable {
    var count: Int
}

struct WebSocketStatus: Codable {
    var clients: Int
}

// GET /api/server/connections -> { "data": [ActiveConnectionInfo] }
struct ActiveConnectionListResponse: Codable {
    var data: [ActiveConnectionInfo]
}

struct ActiveConnectionInfo: Codable, Identifiable {
    var id: String
    var clientName: String?
    var clientType: String?
    var platform: String?
    var appVersion: String?
    var remoteAddress: String?
    var userAgent: String?
    var connectedAt: Int64
    var lastSeenAt: Int64

    var displayTitle: String {
        let name = clientName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        let platformLabel = platform?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !platformLabel.isEmpty { return platformLabel.capitalized }
        return "micaGO Client"
    }

    var subtitle: String {
        // The client runtime ("flutter") isn't useful to the user — omit it.
        var parts: [String] = []
        if let platform, !platform.isEmpty { parts.append(platform) }
        if let appVersion, !appVersion.isEmpty { parts.append("micaGO \(appVersion)") }
        if let remoteAddress, !remoteAddress.isEmpty { parts.append(remoteAddress) }
        return parts.isEmpty ? "Active WebSocket session" : parts.joined(separator: " · ")
    }

    var connectedLabel: String {
        Self.relativeTime(connectedAt)
    }

    var lastSeenLabel: String {
        Self.relativeTime(lastSeenAt)
    }

    private static func relativeTime(_ millis: Int64) -> String {
        guard millis > 0 else { return "unknown" }
        let date = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct PermissionStatus: Codable {
    var fullDiskAccess: PermissionCheck
    var attachments: PermissionCheck
    var automation: PermissionCheck
}

struct PermissionCheck: Codable {
    var status: String   // "ok" | "denied" | "unknown"
    var detail: String?
}

// GET /api/devices -> { "data": [DeviceInfo] }
struct DeviceListResponse: Codable {
    var data: [DeviceInfo]
}

struct DeviceInfo: Codable, Identifiable {
    var id: String
    var name: String
    var platform: String
    var clientType: String
    var appVersion: String?
    var mode: String?
    var pushProvider: String
    var pushEnabled: Bool
    var pushTokenSet: Bool
    var background: Bool?
    var connected: Bool?
    var lastSeenAt: Int64?
    var createdAt: Int64
    var updatedAt: Int64

    /// "{name} - micaGO {version}" — the card's main line (C21u).
    var displayTitle: String {
        if let v = appVersion, !v.isEmpty {
            return "\(name) - micaGO \(v)"
        }
        return name
    }

    /// "LAN" / "LAN + Public" for the secondary line.
    var modeLabel: String {
        switch mode {
        case "lan_public": return "LAN + Public"
        default: return "LAN"
        }
    }

    /// Push capability, shown plainly when not configured (C21u/C22).
    var pushLabel: String {
        if pushProvider == "none" || pushProvider.isEmpty {
            return "not configured"
        }
        return pushEnabled ? "enabled (\(pushProvider))" : "disabled"
    }

    /// Background (FCM wake) capability for the secondary line (C22).
    var backgroundLabel: String {
        (background ?? false) ? "enabled" : "disabled"
    }

    var isConnected: Bool { connected ?? false }

    /// Human "last connected" string from `lastSeenAt`.
    var lastConnectedLabel: String {
        guard let ms = lastSeenAt else { return "never" }
        let date = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: date, relativeTo: Date())
    }
}

import Foundation

// Codable mirrors of the v0.11.3 sync-control API.
// See docs/features/messaging.md.

struct SyncRule: Codable, Identifiable, Hashable {
    var targetKind: String   // "chat" | "handle"
    var targetValue: String
    var syncMode: String     // "allow" | "block" | "inherit"
    var pushMode: String     // "enabled" | "muted" | "inherit"
    var createdAt: Int64
    var updatedAt: Int64

    var id: String { "\(targetKind):\(targetValue)" }
}

struct SyncRulesResponse: Codable {
    var defaultSyncPolicy: String   // "allow_all" | "block_all"
    var defaultPushPolicy: String   // "enabled" | "muted"
    var rules: [SyncRule]
}

struct SyncSettings: Codable, Equatable {
    var backfillMode: String
    var recentMessagesPerChat: Int
    var includeIMessage: Bool
    var includeSMS: Bool
    var includeRCS: Bool
    var includeUnknown: Bool
    var includeDebugInNormal: Bool
    var allowSmsSend: Bool

    static let defaults = SyncSettings(backfillMode: "hybrid",
                                       recentMessagesPerChat: 100,
                                       includeIMessage: true,
                                       includeSMS: true,
                                       includeRCS: true,
                                       includeUnknown: false,
                                       includeDebugInNormal: false,
                                       allowSmsSend: false)

    enum CodingKeys: String, CodingKey {
        case backfillMode
        case recentMessagesPerChat
        case includeIMessage
        case includeSMS
        case includeRCS
        case includeUnknown
        case includeDebugInNormal
        case allowSmsSend
    }

    init(backfillMode: String,
         recentMessagesPerChat: Int,
         includeIMessage: Bool,
         includeSMS: Bool,
         includeRCS: Bool,
         includeUnknown: Bool,
         includeDebugInNormal: Bool,
         allowSmsSend: Bool) {
        self.backfillMode = backfillMode
        self.recentMessagesPerChat = recentMessagesPerChat
        self.includeIMessage = includeIMessage
        self.includeSMS = includeSMS
        self.includeRCS = includeRCS
        self.includeUnknown = includeUnknown
        self.includeDebugInNormal = includeDebugInNormal
        self.allowSmsSend = allowSmsSend
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backfillMode = try c.decode(String.self, forKey: .backfillMode)
        recentMessagesPerChat = try c.decode(Int.self, forKey: .recentMessagesPerChat)
        includeIMessage = try c.decode(Bool.self, forKey: .includeIMessage)
        includeSMS = try c.decode(Bool.self, forKey: .includeSMS)
        includeRCS = try c.decode(Bool.self, forKey: .includeRCS)
        includeUnknown = try c.decode(Bool.self, forKey: .includeUnknown)
        includeDebugInNormal = try c.decode(Bool.self, forKey: .includeDebugInNormal)
        allowSmsSend = try c.decodeIfPresent(Bool.self, forKey: .allowSmsSend) ?? false
    }
}

struct SyncSettingsResponse: Codable {
    var settings: SyncSettings
    var diagnostics: SyncDiagnostics?
}

/// Conversation rows used by the offline test-contact panel.
struct RecentMessagesResponse: Codable {
    var data: [RecentMessage]
}

struct RecentMessage: Codable, Identifiable {
    var guid: String
    var text: String?
    var isFromMe: Bool
    var id: String { guid }
}

// GET /api/chats -> { data: [ChatSummary], meta: {...} }
struct ChatListResponse: Codable {
    var data: [ChatSummary]
}

struct ChatSummary: Codable, Identifiable {
    var guid: String
    var chatIdentifier: String?
    var displayName: String?

    var id: String { guid }

    var label: String {
        if let d = displayName, !d.isEmpty { return d }
        if let c = chatIdentifier, !c.isEmpty { return c }
        return guid
    }
}

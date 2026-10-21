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

// Generic message-list envelope used by the Debug inspector and chat history
// views. Sync Control no longer surfaces a Recent Messages management card.
struct RecentMessagesResponse: Codable {
    var data: [RecentMessage]
}

struct RecentMessage: Codable, Identifiable {
    var guid: String
    var text: String?
    var service: String?
    var dateCreated: Int64?
    var isFromMe: Bool
    var handle: HandleRef?
    var attachments: [RecentAttachment]?

    var id: String { guid }

    /// One-line preview that never leaves a blank row: real text when present,
    /// else a simple bracketed placeholder for the attachment kind.
    var previewLabel: String {
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        if let first = attachments?.first { return first.placeholder }
        return "[空消息]"
    }
}

struct RecentAttachment: Codable, Hashable {
    var displayKind: String?
    var attachmentKind: String?
    var mimeType: String?

    /// A bracketed placeholder ([图片]/[视频]/[语音]/[贴图]/[位置]/[文件]).
    var placeholder: String {
        switch (displayKind ?? attachmentKind ?? "").lowercased() {
        case "image", "photo": return "[图片]"
        case "video": return "[视频]"
        case "audio", "voice": return "[语音]"
        case "sticker": return "[贴图]"
        case "location": return "[位置]"
        case "contact", "vcard": return "[联系人]"
        default:
            if (mimeType ?? "").hasPrefix("image/") { return "[图片]" }
            if (mimeType ?? "").hasPrefix("video/") { return "[视频]" }
            if (mimeType ?? "").hasPrefix("audio/") { return "[语音]" }
            return "[文件]"
        }
    }
}

struct HandleRef: Codable, Hashable {
    var id: String
    var service: String?
}

// GET /api/chats -> { data: [ChatSummary], meta: {...} }
struct ChatListResponse: Codable {
    var data: [ChatSummary]
}

struct ChatSummary: Codable, Identifiable {
    var guid: String
    var chatIdentifier: String?
    var serviceName: String?
    var displayName: String?
    var isArchived: Bool

    var id: String { guid }

    var label: String {
        if let d = displayName, !d.isEmpty { return d }
        if let c = chatIdentifier, !c.isEmpty { return c }
        return guid
    }
}

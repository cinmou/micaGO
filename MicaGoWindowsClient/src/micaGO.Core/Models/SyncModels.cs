namespace MicaGo.Core.Models;

public sealed record MessageDelta(
    IReadOnlyList<Message> Messages,
    IReadOnlyList<string> ChatIds,
    long Cursor,
    bool HasMore);

public sealed record MessageHistoryPage(
    IReadOnlyList<Message> Messages,
    string? NextCursor,
    bool HasMore);

/// <summary>
/// One realtime hint from the WebSocket. When the frame carried a full message
/// payload (message:new / message:updated) it is parsed into <see cref="Message"/>
/// so read receipts and edits apply even when the delta cursor misses them.
/// </summary>
public sealed record RealtimeEvent(string Type, string? ChatId, string? MessageId, Message? Message = null);

public sealed record MessageActionCapabilities(
    bool CanEdit,
    bool CanRetract,
    bool CanDelete,
    string? Reason = null);

public sealed record AttachmentUploadResult(string? FileName);


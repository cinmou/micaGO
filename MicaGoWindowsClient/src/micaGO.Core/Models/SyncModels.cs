namespace MicaGo.Core.Models;

public sealed record MessageDelta(
    IReadOnlyList<Message> Messages,
    IReadOnlyList<string> ChatIds,
    long Cursor,
    bool HasMore);

public sealed record RealtimeEvent(string Type, string? ChatId, string? MessageId);

public sealed record MessageActionCapabilities(
    bool CanEdit,
    bool CanRetract,
    bool CanDelete,
    string? Reason = null);

public sealed record AttachmentUploadResult(string? FileName);


namespace MicaGo.Core.Models;

public enum MessageDeliveryState
{
    Sending,
    Sent,
    Delivered,
    Read,
    Failed,
}

public sealed record Message(
    string Id,
    string ChatId,
    string Text,
    string SentAt,
    bool IsOutgoing,
    MessageDeliveryState DeliveryState,
    string? SenderName = null,
    string? AttachmentLabel = null,
    long DateCreated = 0,
    IReadOnlyList<Attachment>? Attachments = null,
    string? AssociatedMessageGuid = null,
    int AssociatedMessageType = 0,
    string? ReplyToGuid = null,
    string? ExpressiveSendStyleId = null,
    bool IsEdited = false,
    bool IsPending = false,
    string? ErrorText = null,
    string? PresentationId = null,
    double UploadProgress = 0,
    string? Subject = null,
    string? SemanticKind = null,
    string? RenderRecommendation = null,
    bool IsRetracted = false,
    int ItemType = 0,
    int GroupActionType = 0,
    string? GroupTitle = null,
    string? BalloonBundleId = null,
    IReadOnlyList<string>? Reactions = null,
    string? ReplyPreview = null,
    bool CompactWithPrevious = false,
    bool CompactWithNext = false,
    bool ShowBubbleTail = true,
    bool ShowFooter = false,
    bool IsBigEmoji = false,
    bool IsStickerOnly = false,
    bool IsSeparator = false,
    string? SeparatorLabel = null,
    bool ShowSenderLabel = true,
    string? SenderIdentity = null,
    string? SenderAvatarPath = null,
    bool ShowSenderAvatar = false,
    string? EffectLabel = null,
    int MergedSystemCount = 1,
    bool IsPresentationSystem = false,
    bool ReserveSenderAvatarSpace = false,
    long SourceRowId = 0)
{
    public IReadOnlyList<Attachment> Media => Attachments ?? [];
    public string PresentationKey => PresentationId ?? Id;
    public string TimelineKey => string.Concat(ChatId, "\u001f", PresentationKey);
    public bool IsReaction => AssociatedMessageType is >= 2000 and <= 3005 && !string.IsNullOrWhiteSpace(AssociatedMessageGuid);
    public bool IsServiceEvent => string.Equals(SemanticKind,"service_event",StringComparison.OrdinalIgnoreCase) || ItemType>0 || GroupActionType>0 || !string.IsNullOrWhiteSpace(GroupTitle);
}

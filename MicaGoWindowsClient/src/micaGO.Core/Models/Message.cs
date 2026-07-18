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
    string? AttachmentLabel = null)
{
    public string Footer => DeliveryState switch
    {
        MessageDeliveryState.Sending => "Sending",
        MessageDeliveryState.Sent => "Sent",
        MessageDeliveryState.Delivered => "Delivered",
        MessageDeliveryState.Read => $"Read · {SentAt}",
        MessageDeliveryState.Failed => "Failed to send",
        _ => SentAt,
    };
}

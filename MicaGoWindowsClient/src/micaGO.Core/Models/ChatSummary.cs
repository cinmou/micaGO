namespace MicaGo.Core.Models;

public sealed record ChatSummary(
    string Id,
    string Title,
    string Preview,
    string Time,
    int UnreadCount,
    string Initials,
    bool IsMuted = false,
    string ServiceLabel = "Unknown",
    bool CanSendText = false,
    bool IsPinned = false,
    bool IsGroup = false)
{
    public double UnreadBadgeOpacity => UnreadCount > 0 ? 1 : 0;
}

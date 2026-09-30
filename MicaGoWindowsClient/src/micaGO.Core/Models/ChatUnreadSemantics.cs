namespace MicaGo.Core.Models;

public enum UnreadBadgeKind { None, Dot, Count }

public static class ChatUnreadSemantics
{
    public static UnreadBadgeKind Badge(bool hasUnread, int count, bool muted) =>
        !hasUnread ? UnreadBadgeKind.None : muted || count <= 0 ? UnreadBadgeKind.Dot : UnreadBadgeKind.Count;

    public static ChatSummary Advance(ChatSummary route, long timestamp, bool outgoing, bool viewed, bool firstObservation)
    {
        if (timestamp < route.UpdatedAt) return route;
        var unseen = firstObservation && !outgoing && !viewed;
        return route with {
            UpdatedAt = timestamp,
            LatestFromMe = outgoing,
            HasUnread = !viewed && !outgoing && (unseen || route.HasUnread),
            UnreadCount = viewed || outgoing ? 0 : unseen ? route.UnreadCount + 1 : route.UnreadCount,
        };
    }
}

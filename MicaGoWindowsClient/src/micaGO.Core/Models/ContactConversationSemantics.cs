namespace MicaGo.Core.Models;

/// <summary>Contact identity groups presentation; server routes still own history and sends.</summary>
public static class ContactConversationSemantics
{
    public static ChatSummary Merge(IReadOnlyList<ChatSummary> routes, string? savedRoute)
    {
        if (routes.Count == 0) throw new ArgumentException("At least one route is required.", nameof(routes));
        var ordered = routes.OrderByDescending(route => route.UpdatedAt).ToArray();
        var newest = ordered[0];
        var sender = ordered.FirstOrDefault(route => route.CanSendText && string.Equals(route.Id, savedRoute, StringComparison.OrdinalIgnoreCase))
            ?? ordered.FirstOrDefault(route => route.CanSendText && route.ServiceLabel.Equals("iMessage", StringComparison.OrdinalIgnoreCase))
            ?? ordered.FirstOrDefault(route => route.CanSendText)
            ?? newest;
        return newest with
        {
            RouteIds = ordered.Select(route => route.Id).ToArray(),
            PrimaryRouteId = sender.Id,
            CanSendText = sender.CanSendText,
            ServiceLabel = sender.ServiceLabel,
            UnreadCount = ordered.Sum(route => route.UnreadCount),
            HasUnread = ordered.Any(route => route.HasUnread),
            IsPinned = ordered.Any(route => route.IsPinned),
            IsMuted = ordered.All(route => route.IsMuted),
            KeepRoutesSeparate = false
        };
    }

    public static bool SameRoutes(ChatSummary chat, IEnumerable<string> routes) =>
        (chat.RouteIds is { Count: > 0 } ? chat.RouteIds : [chat.Id])
            .ToHashSet(StringComparer.OrdinalIgnoreCase).SetEquals(routes);
}

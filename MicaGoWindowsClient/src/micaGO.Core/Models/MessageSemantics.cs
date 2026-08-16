using System.Text.RegularExpressions;

namespace MicaGo.Core.Models;

public static partial class MessageSemantics
{
    private static readonly HashSet<string> AttachmentPlaceholders = new(StringComparer.OrdinalIgnoreCase)
    {
        "message", "attachment", "file", "obj", "object", "null",
    };

    public static string VisibleText(string? value)
    {
        var text=Whitespace().Replace((value??string.Empty).Replace('\uFFFC',' ').Replace('\uFFFD',' ').Trim()," ");
        if(text.Length==0)return string.Empty;
        var real=text.Any(character=>char.IsLetterOrDigit(character)||character>0x7f);
        return real?text:string.Empty;
    }

    /// <summary>Flutter-compatible text for a conversation-list preview.</summary>
    public static string PreviewText(string? value, bool hasMessage = true)
    {
        var text = VisibleText(value);
        return text.Length == 0 || AttachmentPlaceholders.Contains(text)
            ? hasMessage ? "[Attachment]" : string.Empty
            : text;
    }

    public static string PreviewText(Message message)
    {
        var text = VisibleText(message.Text);
        if (text.Length > 0 && !AttachmentPlaceholders.Contains(text)) return text;
        if (message.Media.Count > 0 || !string.IsNullOrWhiteSpace(message.AttachmentLabel)) return "[Attachment]";
        return message.IsRetracted ? "Message unsent" : PreviewText(text);
    }

    public static bool AttachmentSendMatches(Message local, Message server)
    {
        foreach (var left in local.Media)
        foreach (var right in server.Media)
        {
            var leftName = left.FileName.Trim().ToLowerInvariant();
            var rightName = right.FileName.Trim().ToLowerInvariant();
            if (leftName.Length > 0 && leftName != "attachment" && leftName == rightName) return true;
            if (Stem(leftName) is { Length: > 0 } stem && stem != "attachment" && stem == Stem(rightName)) return true;
            if (left.Size > 0 && left.Size == right.Size) return true;
        }
        return false;
    }

    public static bool ShouldReconcile(Message local, Message server)
    {
        if (!local.ChatId.Equals(server.ChatId, StringComparison.OrdinalIgnoreCase)
            || !local.IsOutgoing || !server.IsOutgoing || string.IsNullOrWhiteSpace(server.Id)) return false;
        if (local.Id == server.Id) return true;
        if (local.DateCreated <= 0 || server.DateCreated <= 0) return false;
        var distance = Math.Abs(local.DateCreated - server.DateCreated);
        var localText = VisibleText(local.Text); var serverText = VisibleText(server.Text);
        if (local.Media.Count > 0 && localText.Length == 0)
            return distance <= TimeSpan.FromMinutes(5).TotalMilliseconds && serverText.Length == 0 && AttachmentSendMatches(local, server);
        return localText.Length > 0 && string.Equals(localText, serverText, StringComparison.OrdinalIgnoreCase) && distance <= TimeSpan.FromMinutes(2).TotalMilliseconds;
    }

    public static Message? MatchingPending(IEnumerable<Message> rows, Message server)
    {
        var pending = rows.Where(row => row.IsPending && row.DeliveryState != MessageDeliveryState.Failed).ToArray();
        var exact = pending.Where(row => ShouldReconcile(row, server)).OrderBy(row => Math.Abs(row.DateCreated - server.DateCreated)).ToArray();
        if (exact.Length > 0) return exact[0];
        if (!server.IsOutgoing || VisibleText(server.Text).Length > 0 || server.Media.Count == 0 || server.DateCreated <= 0) return null;
        var fallback = pending.Where(row => row.IsOutgoing && row.Media.Count > 0 && VisibleText(row.Text).Length == 0 && row.DateCreated > 0 && Math.Abs(row.DateCreated - server.DateCreated) <= TimeSpan.FromMinutes(5).TotalMilliseconds).ToArray();
        return fallback.Length == 1 ? fallback[0] : null;
    }

    /// <summary>
    /// Applies server-authoritative content to an already presented row without
    /// changing that row's identity or chronological slot. Server confirmation
    /// timestamps routinely differ by a few milliseconds from optimistic send
    /// timestamps; adopting them caused ListView.Move and recycled the bubble.
    /// </summary>
    /// <summary>
    /// C74: merges a freshly loaded snapshot into the rows already on screen.
    ///
    /// Cache-first selection and cursor history pages can complete while
    /// realtime frames append rows. A wholesale replace would let a late page
    /// wipe messages that had just been delivered live.
    ///
    /// Rules: snapshot rows win (they carry the newest server state, with the
    /// on-screen presentation identity carried across); local rows the snapshot
    /// does not contain survive when they are still pending, or newer than the
    /// snapshot's own window; anything older is dropped so server-side deletes
    /// still disappear.
    /// </summary>
    public static IReadOnlyList<Message> MergeSnapshot(
        IReadOnlyList<Message> presented,
        IEnumerable<Message> snapshot,
        IReadOnlySet<string>? allowedChatIds = null)
    {
        static bool IsAllowed(Message row, IReadOnlySet<string>? allowed) =>
            allowed is null || allowed.Contains(row.ChatId);

        var byIdentity = new Dictionary<(string, string), Message>();
        foreach (var row in presented)
        {
            if (row.IsSeparator || !IsAllowed(row, allowedChatIds)) continue;
            byIdentity[(row.ChatId, row.Id)] = row;
        }

        var merged = new List<Message>();
        var seen = new HashSet<(string, string)>();
        var consumedPending = new HashSet<(string, string)>();
        var availablePending = presented
            .Where(row => row.IsPending && IsAllowed(row, allowedChatIds))
            .ToList();
        foreach (var row in snapshot)
        {
            if (row.IsSeparator || !IsAllowed(row, allowedChatIds)) continue;
            var key = (row.ChatId, row.Id);
            if (byIdentity.TryGetValue(key, out var existing))
            {
                merged.Add(ReconcilePresentation(existing, row));
            }
            else
            {
                // Flutter MessageCollection parity: consume at most one pending
                // row per server row. Removing the match from this candidate set
                // prevents two rapid identical sends from claiming the same
                // optimistic bubble.
                var pending = MatchingPending(availablePending, row);
                if (pending is null)
                {
                    merged.Add(row);
                }
                else
                {
                    merged.Add(ReconcilePresentation(pending, row));
                    availablePending.Remove(pending);
                    consumedPending.Add((pending.ChatId, pending.Id));
                }
            }
            seen.Add(key);
        }

        if (presented.Count > 0)
        {
            var floor = merged.Count == 0 ? long.MinValue : merged.Min(row => row.DateCreated);
            foreach (var row in presented)
            {
                if (row.IsSeparator || !IsAllowed(row, allowedChatIds) || seen.Contains((row.ChatId, row.Id)) || consumedPending.Contains((row.ChatId, row.Id))) continue;
                if (row.IsPending || row.DateCreated >= floor) merged.Add(row);
            }
        }

        return merged.OrderBy(row => row.DateCreated)
            .ThenBy(row => row.SourceRowId)
            .ThenBy(row => row.ChatId, StringComparer.OrdinalIgnoreCase)
            .ThenBy(row => row.Id, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    public static Message ReconcilePresentation(Message presented, Message server) => server with
    {
        PresentationId = presented.PresentationKey,
        DateCreated = presented.DateCreated > 0 ? presented.DateCreated : server.DateCreated,
    };

    private static string Stem(string value) => Path.GetFileNameWithoutExtension(value);
    [GeneratedRegex(@"\s+")]
    private static partial Regex Whitespace();
}

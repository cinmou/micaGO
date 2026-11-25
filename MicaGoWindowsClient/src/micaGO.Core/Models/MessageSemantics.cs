using System.Text.RegularExpressions;

namespace MicaGo.Core.Models;

public static partial class MessageSemantics
{
    private static readonly HashSet<string> AttachmentPlaceholders = new(StringComparer.OrdinalIgnoreCase)
    {
        "message", "attachment", "file", "obj", "object", "null",
    };

    public const long MaxOutgoingAttachmentBytes = 100L * 1024 * 1024;

    public static string VisibleText(string? value)
    {
        var text=Whitespace().Replace((value??string.Empty).Replace('\uFFFC',' ').Replace('\uFFFD',' ').Trim()," ");
        if(text.Length==0)return string.Empty;
        var real=text.Any(character=>char.IsLetterOrDigit(character)||character>0x7f);
        return real?text:string.Empty;
    }

    /// <summary>
    /// Comparable text for send reconciliation: also strips BOM and emoji
    /// variation selectors (U+FE0E/U+FE0F) so keyboard vs macOS Messages
    /// presentation differences (e.g. "❤️" vs "❤") still reconcile cleanly.
    /// </summary>
    public static string ComparableText(string? value)
    {
        var stripped = (value ?? string.Empty)
            .Replace("\uFEFF", string.Empty, StringComparison.Ordinal)
            .Replace("\uFE0E", string.Empty, StringComparison.Ordinal)
            .Replace("\uFE0F", string.Empty, StringComparison.Ordinal);
        return VisibleText(stripped);
    }

    /// <summary>
    /// Visual-area-balanced chat image sizing matching the Flutter client:
    /// 1:2 portrait stays 153x306, 1:1 square narrows to 228x228, wide images
    /// cap at 276 px, and ultra-tall screenshots clamp to 0.45 with a badge.
    /// </summary>
    public static (double Width, double Height, bool IsLongImage) ComputeChatImageSize(
        double pixelWidth,
        double pixelHeight,
        double maxWidth = 276,
        double maxHeight = 306)
    {
        const double maxSquareArea = 228.0 * 228.0;
        const double minAspect = 0.45;
        const double maxAspect = 2.6;
        const double longImageRatioThreshold = 0.42;
        if (pixelWidth <= 0 || pixelHeight <= 0)
        {
            return (240, 170, false);
        }
        var rawAspect = pixelWidth / pixelHeight;
        var isLongImage = rawAspect < longImageRatioThreshold;
        var aspect = Math.Clamp(rawAspect, minAspect, maxAspect);
        var width = Math.Min(maxWidth, maxHeight * aspect);
        var height = width / aspect;
        var area = width * height;
        if (area > maxSquareArea)
        {
            var scale = Math.Sqrt(maxSquareArea / area);
            width *= scale;
            height *= scale;
        }
        return (Math.Max(44, width), Math.Max(44, height), isLongImage);
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
        if (message.IsRetracted) return "Message unsent";
        var text = VisibleText(message.Text);
        if (text.Length > 0 && !AttachmentPlaceholders.Contains(text)) return text;
        if (message.Media.Count > 0 || !string.IsNullOrWhiteSpace(message.AttachmentLabel)) return "[Attachment]";
        return PreviewText(text);
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
        var localText = ComparableText(local.Text); var serverText = ComparableText(server.Text);
        if (local.Media.Count > 0 && localText.Length == 0)
            return distance <= TimeSpan.FromMinutes(5).TotalMilliseconds && serverText.Length == 0 && AttachmentSendMatches(local, server);
        return localText.Length > 0 && string.Equals(localText, serverText, StringComparison.OrdinalIgnoreCase) && distance <= TimeSpan.FromMinutes(2).TotalMilliseconds;
    }

    public static Message? MatchingPending(IEnumerable<Message> rows, Message server)
    {
        if(server.IsPending)return null;
        var pending = rows.Where(row => row.IsPending && row.ChatId.Equals(server.ChatId,StringComparison.OrdinalIgnoreCase)).ToArray();
        var exact = pending.Where(row => ShouldReconcile(row, server)).OrderBy(row => Math.Abs(row.DateCreated - server.DateCreated)).ToArray();
        if (exact.Length > 0) return exact[0];
        if (!server.IsOutgoing || ComparableText(server.Text).Length > 0 || server.Media.Count == 0 || server.DateCreated <= 0) return null;
        var fallback = pending.Where(row => row.DeliveryState != MessageDeliveryState.Failed && row.IsOutgoing && row.Media.Count > 0 && ComparableText(row.Text).Length == 0 && row.DateCreated > 0 && Math.Abs(row.DateCreated - server.DateCreated) <= TimeSpan.FromMinutes(5).TotalMilliseconds).ToArray();
        return fallback.Length == 1 ? fallback[0] : null;
    }

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
            if(!seen.Add(key))continue;
            byIdentity.TryGetValue(key,out var existing);
            var candidates=existing is null?availablePending:availablePending.Where(p=>(p.DeliveryState is MessageDeliveryState.Failed or MessageDeliveryState.AwaitingConfirmation) && p.DateCreated<=row.DateCreated);
            var pending=existing is not null && existing.PresentationKey!=existing.Id ? null : MatchingPending(candidates,row);
            if(pending is not null) {
                merged.Add(ReconcilePresentation(pending,row));availablePending.Remove(pending);consumedPending.Add((pending.ChatId,pending.Id));
            } else merged.Add(existing is null?row:ReconcilePresentation(existing,row));
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

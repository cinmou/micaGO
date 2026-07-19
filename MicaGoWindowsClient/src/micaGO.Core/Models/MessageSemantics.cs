using System.Text.RegularExpressions;

namespace MicaGo.Core.Models;

public static partial class MessageSemantics
{
    public static string VisibleText(string? value)
    {
        var text=Whitespace().Replace((value??string.Empty).Replace('\uFFFC',' ').Replace('\uFFFD',' ').Trim()," ");
        if(text.Length==0)return string.Empty;
        var real=text.Any(character=>char.IsLetterOrDigit(character)||character>0x7f);
        return real?text:string.Empty;
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
        if (!local.IsOutgoing || !server.IsOutgoing || string.IsNullOrWhiteSpace(server.Id)) return false;
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

    private static string Stem(string value) => Path.GetFileNameWithoutExtension(value);
    [GeneratedRegex(@"\s+")]
    private static partial Regex Whitespace();
}

using MicaGo.Infrastructure.Api;
using MicaGo.Infrastructure.Contracts;

namespace MicaGo.Infrastructure.Connection;

public enum NotificationReplyResult { Sent, Pending, Rejected, Failed }

public sealed class NotificationReplySender(Func<IMicaGoApi?> api, Func<string?> deviceId)
{
    public async Task<NotificationReplyResult> SendAsync(string chatGuid, string notifiedDeviceId, string text, CancellationToken ct = default)
    {
        var body = text.Trim();
        if (string.IsNullOrWhiteSpace(chatGuid) || body.Length == 0 || body.Length > 65536) return NotificationReplyResult.Failed;
        if (string.IsNullOrWhiteSpace(notifiedDeviceId) || notifiedDeviceId != deviceId()) return NotificationReplyResult.Rejected;
        var client = api();
        if (client is null) return NotificationReplyResult.Rejected;
        try
        {
            // Ordinary send: no thread/reply association and no automatic resend.
            await client.SendTextAsync(chatGuid, body, "reply-" + Guid.NewGuid().ToString("N"), ct);
            return ReferenceEquals(client, api()) ? NotificationReplyResult.Sent : NotificationReplyResult.Pending;
        }
        catch (MicaGoApiException error) when (error.StatusCode == 401) { return NotificationReplyResult.Rejected; }
        catch (MicaGoApiException error) when (error.StatusCode == 202 || error.Code == "send_confirmation_timeout") { return NotificationReplyResult.Pending; }
        catch (HttpRequestException) { return NotificationReplyResult.Pending; }
        catch (OperationCanceledException) { return NotificationReplyResult.Pending; }
        catch { return NotificationReplyResult.Failed; }
    }
}

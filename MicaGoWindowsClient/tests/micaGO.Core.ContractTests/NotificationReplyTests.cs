using MicaGo.Core.Models;
using MicaGo.Infrastructure.Api;
using MicaGo.Infrastructure.Connection;

internal static class NotificationReplyTests
{
    private sealed class Api : RealtimeSyncTests.FakeApi
    {
        public int Calls;
        public Exception? Failure;
        public string? Route, Body, Temp;
        public override Task<Message> SendTextAsync(string chatId, string text, string? tempId = null, CancellationToken cancellationToken = default)
        {
            Calls++; Route = chatId; Body = text; Temp = tempId;
            return Failure is {} error ? Task.FromException<Message>(error) : Task.FromResult(new Message("sent", chatId, text, "", true, MessageDeliveryState.Sent));
        }
    }
    public static async Task RunAsync()
    {
        var api = new Api();
        var sender = new NotificationReplySender(() => api, () => "current-device");
        if (await sender.SendAsync("route-a", "old-device", "private") != NotificationReplyResult.Rejected || api.Calls != 0) throw new Exception("Old notification sent with a new device credential.");
        if (await sender.SendAsync("route-a", "current-device", "  ") != NotificationReplyResult.Failed || api.Calls != 0) throw new Exception("Empty reply was sent.");
        if (await sender.SendAsync("route-a", "current-device", "  hello  ") != NotificationReplyResult.Sent || api.Route != "route-a" || api.Body != "hello" || api.Temp?.StartsWith("reply-") != true) throw new Exception("Reply did not use an ordinary route-scoped send.");
        api.Failure = new MicaGoApiException("awaiting confirmation", 202, code: "send_confirmation_timeout");
        if (await sender.SendAsync("route-a", "current-device", "hello") != NotificationReplyResult.Pending || api.Calls != 2) throw new Exception("Unconfirmed reply retried or became failed.");
        api.Failure = new MicaGoApiException("rejected", 401);
        if (await sender.SendAsync("route-a", "current-device", "hello") != NotificationReplyResult.Rejected) throw new Exception("Reply ignored revoked credential.");
    }
}

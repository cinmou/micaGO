using System.Net;
using MicaGo.Infrastructure.Api;
using MicaGo.Infrastructure.Connection;
using MicaGo.Infrastructure.Storage;

internal static class CredentialSessionTests
{
    private sealed class Handler(Func<HttpRequestMessage, Task<HttpResponseMessage>> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) => send(request);
    }

    public static async Task RunAsync()
    {
        var session = new CredentialSession(); var count = 0; var calls = 0;
        session.Rejected += (_, _) => count++;
        var pending = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var client = new HttpClient(new CredentialSessionHandler(session)
        {
            InnerHandler = new Handler(request =>
            {
                calls++;
                return request.RequestUri!.AbsolutePath == "/late" ? pending.Task : Task.FromResult(new HttpResponseMessage(HttpStatusCode.Unauthorized));
            }),
        });
        var late = client.GetAsync("https://relay.example/late");
        await Rejects(client.GetAsync("https://relay.example/rejected"));
        pending.SetResult(new HttpResponseMessage(HttpStatusCode.OK));
        await Rejects(late);
        await Rejects(client.GetAsync("https://relay.example/no-retry"));
        if (count != 1 || calls != 2) throw new Exception("Rejected session emitted duplicates or kept making requests.");
        var permitted = new CredentialSession();
        using var denied = new HttpClient(new CredentialSessionHandler(permitted) { InnerHandler = new Handler(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.Forbidden))) });
        using var reply = await denied.GetAsync("https://relay.example/action");
        if (permitted.IsRejected) throw new Exception("Action permission failure revoked credential.");

        var directory = Directory.CreateTempSubdirectory("micago-media-lock-");
        try
        {
            var media = new MediaCache(directory.FullName);
            var source = Path.Combine(directory.FullName, "source"); await File.WriteAllBytesAsync(source, [1, 2]);
            await media.SeedAsync("private", source);
            media.AccessAllowed = false;
            try { media.TryGetPath("private"); throw new Exception("Rejected media cache remained readable."); }
            catch (MicaGoApiException error) when (error.StatusCode == 401) { }
        }
        finally { directory.Delete(true); }
    }

    private static async Task Rejects(Task task)
    {
        try { await task; throw new Exception("Rejected session accepted a response."); }
        catch (MicaGoApiException error) when (error.StatusCode == 401) { }
    }
}

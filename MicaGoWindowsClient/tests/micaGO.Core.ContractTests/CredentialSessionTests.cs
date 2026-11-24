using System.Net;
using System.Text;
using MicaGo.Core.Connection;
using MicaGo.Infrastructure.Api;
using MicaGo.Infrastructure.Connection;
using MicaGo.Infrastructure.Storage;

internal static class CredentialSessionTests
{
    private sealed class Handler(Func<HttpRequestMessage, Task<HttpResponseMessage>> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) => send(request);
    }

    private sealed class MemoryConnectionStore(SavedConnection? saved) : IConnectionStore
    {
        public SavedConnection? Saved { get; private set; } = saved;
        public Task<SavedConnection?> LoadAsync(CancellationToken cancellationToken = default) => Task.FromResult(Saved);
        public Task SaveAsync(ConnectionProfile profile, string token, CancellationToken cancellationToken = default)
        {
            Saved = new SavedConnection(profile, token);
            return Task.CompletedTask;
        }
        public Task ClearAsync(CancellationToken cancellationToken = default)
        {
            Saved = null;
            return Task.CompletedTask;
        }
    }

    private static HttpResponseMessage StructuredUnauthorized() =>
        new(HttpStatusCode.Unauthorized)
        {
            Content = new StringContent("""{"error":{"code":"unauthorized","message":"unauthorized"}}""", Encoding.UTF8, "application/json"),
        };

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
                return request.RequestUri!.AbsolutePath == "/late" ? pending.Task : Task.FromResult(StructuredUnauthorized());
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

        // A proxy/gateway HTML 401 page is not a micaGO credential revocation.
        var proxySession = new CredentialSession();
        using var proxyClient = new HttpClient(new CredentialSessionHandler(proxySession)
        {
            InnerHandler = new Handler(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.Unauthorized)
            {
                Content = new StringContent("<html><body>Sign in</body></html>", Encoding.UTF8, "text/html"),
            })),
        });
        using var proxyReply = await proxyClient.GetAsync("https://proxy.example/api/chats");
        if (proxySession.IsRejected || proxyReply.StatusCode != HttpStatusCode.Unauthorized)
            throw new Exception("Proxy HTML 401 incorrectly revoked device credential.");

        // Multi-route fallback: public returns structured 401 while LAN is healthy -> keep pairing and connect to LAN.
        var lanEndpoint = new ConnectionEndpoint(EndpointKind.Lan, "https://192.168.1.9:3001", "wss://192.168.1.9:3001/ws", TlsFingerprint: new string('a', 64));
        var publicEndpoint = new ConnectionEndpoint(EndpointKind.Public, "https://relay.example.com", "wss://relay.example.com/ws");
        var selector = new EndpointSelector((endpoint, _, _) => Task.FromResult(
            endpoint.Kind == EndpointKind.Public
                ? new EndpointProbeResult(endpoint, false, TimeSpan.FromMilliseconds(5), "The token was rejected.", CredentialRejected: true)
                : new EndpointProbeResult(endpoint, true, TimeSpan.FromMilliseconds(10))));
        var selected = await selector.SelectAsync([publicEndpoint, lanEndpoint], ConnectionMode.LanFirst, new string('b', 64));
        if (!string.Equals(selected.Endpoint.BaseUrl, lanEndpoint.BaseUrl, StringComparison.OrdinalIgnoreCase))
            throw new Exception("EndpointSelector did not fall back to available LAN endpoint.");

        var allBadSelector = new EndpointSelector((endpoint, _, _) => Task.FromResult(
            endpoint.Kind == EndpointKind.Public
                ? new EndpointProbeResult(endpoint, false, TimeSpan.FromMilliseconds(5), "The token was rejected.", CredentialRejected: true)
                : new EndpointProbeResult(endpoint, false, TimeSpan.FromMilliseconds(10), "Connection timed out.")));
        try
        {
            await allBadSelector.SelectAsync([lanEndpoint, publicEndpoint], ConnectionMode.LanFirst, new string('b', 64));
            throw new Exception("All-failed candidates with structured 401 should throw CredentialRejectedException.");
        }
        catch (CredentialRejectedException) { }

        // ConnectionManager: manually selected public route returns 401, but LAN route succeeds -> fall back without clearing pairing.
        var savedProfile = new ConnectionProfile(
            "Mac",
            publicEndpoint.BaseUrl,
            publicEndpoint.WebSocketUrl,
            ConnectionMode.LanFirst,
            "r1",
            [lanEndpoint, publicEndpoint],
            SelectedBaseUrl: publicEndpoint.BaseUrl,
            TlsFingerprint: lanEndpoint.TlsFingerprint,
            DeviceId: "dev-1");
        var memoryStore = new MemoryConnectionStore(new SavedConnection(savedProfile, new string('c', 64)));
        using var manager = new ConnectionManager(memoryStore, selector);
        var restored = await manager.TryRestoreAsync();
        if (!restored || manager.TokenRejected || !string.Equals(manager.ActiveEndpoint?.Endpoint.BaseUrl, lanEndpoint.BaseUrl, StringComparison.OrdinalIgnoreCase))
            throw new Exception("ConnectionManager cleared pairing instead of falling back to available LAN route.");

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

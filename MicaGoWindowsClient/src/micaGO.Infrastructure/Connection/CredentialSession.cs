using System.Net;
using MicaGo.Infrastructure.Api;

namespace MicaGo.Infrastructure.Connection;

/// <summary>A rejection is terminal for this API instance, including late replies.</summary>
public sealed class CredentialSession
{
    private int _rejected;
    public bool IsRejected => Volatile.Read(ref _rejected) != 0;
    public event EventHandler? Rejected;
    public void Reject()
    {
        if (Interlocked.Exchange(ref _rejected, 1) == 0) Rejected?.Invoke(this, EventArgs.Empty);
    }
    public void EnsureAllowed()
    {
        if (IsRejected) throw new MicaGoApiException("The server rejected this device credential. Pair again.", 401);
    }
}

public sealed class CredentialSessionHandler(CredentialSession session) : DelegatingHandler
{
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        session.EnsureAllowed();
        var response = await base.SendAsync(request, cancellationToken);
        if (response.StatusCode == HttpStatusCode.Unauthorized) session.Reject();
        try { session.EnsureAllowed(); }
        catch { response.Dispose(); throw; }
        return response;
    }
}

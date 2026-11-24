using System.Net;
using System.Text.Json;
using MicaGo.Infrastructure.Api;

namespace MicaGo.Infrastructure.Connection;

/// <summary>A rejection is terminal for this API instance, including late replies.</summary>
public sealed class CredentialSession
{
    private const int MaxAuthErrorBodyBytes = 8192;
    private int _rejected;
    public bool IsRejected => Volatile.Read(ref _rejected) != 0;
    public event EventHandler? Rejected;
    public void Reject()
    {
        if (Interlocked.Exchange(ref _rejected, 1) == 0) Rejected?.Invoke(this, EventArgs.Empty);
    }
    public void EnsureAllowed()
    {
        if (IsRejected) throw new MicaGoApiException("The server rejected this device credential. Pair again.", 401, code: "unauthorized");
    }

    /// <summary>
    /// Only a structured micaGO 401 JSON envelope (<c>{"error":{"code":"unauthorized"}}</c>)
    /// proves device credential revocation; proxy HTML login pages do not.
    /// </summary>
    public static async Task<bool> IsStructuredUnauthorizedAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        if (response.StatusCode != HttpStatusCode.Unauthorized || response.Content is null) return false;
        try
        {
            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
            var buffer = new byte[MaxAuthErrorBodyBytes + 1];
            var total = 0;
            while (total < buffer.Length)
            {
                var read = await stream.ReadAsync(buffer.AsMemory(total, buffer.Length - total), cancellationToken);
                if (read == 0) break;
                total += read;
            }
            if (total == 0 || total > MaxAuthErrorBodyBytes) return false;
            using var document = JsonDocument.Parse(buffer.AsMemory(0, total));
            if (document.RootElement.ValueKind != JsonValueKind.Object) return false;
            if (!document.RootElement.TryGetProperty("error", out var error) || error.ValueKind != JsonValueKind.Object) return false;
            return error.TryGetProperty("code", out var code)
                && code.ValueKind == JsonValueKind.String
                && string.Equals(code.GetString(), "unauthorized", StringComparison.OrdinalIgnoreCase);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch { return false; }
    }
}

public sealed class CredentialSessionHandler(CredentialSession session) : DelegatingHandler
{
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        session.EnsureAllowed();
        var response = await base.SendAsync(request, cancellationToken);
        if (response.StatusCode == HttpStatusCode.Unauthorized
            && await CredentialSession.IsStructuredUnauthorizedAsync(response, cancellationToken))
        {
            session.Reject();
        }
        try { session.EnsureAllowed(); }
        catch { response.Dispose(); throw; }
        return response;
    }
}

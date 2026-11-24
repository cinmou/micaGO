using System.Diagnostics;
using System.Net.Http.Headers;
using System.Text.Json;
using MicaGo.Core.Connection;

namespace MicaGo.Infrastructure.Connection;

public sealed record EndpointProbeResult(
    ConnectionEndpoint Endpoint,
    bool IsAvailable,
    TimeSpan Latency,
    string? Error = null,
    bool CredentialRejected = false);

public sealed class EndpointSelector
{
    private static readonly TimeSpan ProbeTimeout = TimeSpan.FromSeconds(6);
    private readonly Func<ConnectionEndpoint, string, CancellationToken, Task<EndpointProbeResult>>? _probeOverride;

    public EndpointSelector() : this(null) { }

    public EndpointSelector(Func<ConnectionEndpoint, string, CancellationToken, Task<EndpointProbeResult>>? probeOverride)
    {
        _probeOverride = probeOverride;
    }

    /// <param name="excludeBaseUrl">A route already tried (the chosen route) to skip.</param>
    /// <param name="observe">Receives every probe result (Settings route card).</param>
    public async Task<EndpointProbeResult> SelectAsync(
        IReadOnlyList<ConnectionEndpoint> endpoints,
        ConnectionMode mode,
        string token,
        CancellationToken cancellationToken = default,
        string? excludeBaseUrl = null,
        Action<EndpointProbeResult>? observe = null)
    {
        if (excludeBaseUrl is not null)
        {
            endpoints = endpoints
                .Where(endpoint => !string.Equals(endpoint.BaseUrl, excludeBaseUrl, StringComparison.OrdinalIgnoreCase))
                .ToArray();
        }
        var lan = endpoints.Where(endpoint => endpoint.Kind == EndpointKind.Lan).ToArray();
        var publicEndpoints = endpoints.Where(endpoint => endpoint.Kind == EndpointKind.Public).ToArray();
        var anyRejected = false;

        if (mode != ConnectionMode.PublicOnly)
        {
            var (selectedLan, lanRejected) = await SelectFastestAsync(lan, token, cancellationToken, observe);
            if (selectedLan is not null)
            {
                return selectedLan;
            }
            anyRejected |= lanRejected;
        }

        if (mode != ConnectionMode.LanOnly)
        {
            var (selectedPublic, publicRejected) = await SelectFastestAsync(publicEndpoints, token, cancellationToken, observe);
            if (selectedPublic is not null)
            {
                return selectedPublic;
            }
            anyRejected |= publicRejected;
        }

        if (anyRejected)
        {
            throw new CredentialRejectedException();
        }

        throw new ConnectionException("No advertised endpoint passed both the health and authentication checks.");
    }

    private async Task<(EndpointProbeResult? Selected, bool AnyRejected)> SelectFastestAsync(
        IReadOnlyList<ConnectionEndpoint> endpoints,
        string token,
        CancellationToken cancellationToken,
        Action<EndpointProbeResult>? observe)
    {
        if (endpoints.Count == 0)
        {
            return (null, false);
        }

        var results = await Task.WhenAll(endpoints.Select(endpoint => ProbeAsync(endpoint, token, cancellationToken)));
        foreach (var result in results) observe?.Invoke(result);
        var selected = results
            .Where(result => result.IsAvailable)
            .OrderBy(result => result.Latency)
            .FirstOrDefault();
        return (selected, selected is null && results.Any(result => result.CredentialRejected));
    }

    /// <summary>Health + auth check of one route; never throws for network errors.</summary>
    public Task<EndpointProbeResult> ProbeAsync(
        ConnectionEndpoint endpoint,
        string token,
        CancellationToken cancellationToken = default) =>
        _probeOverride is not null ? _probeOverride(endpoint, token, cancellationToken) : ProbeCoreAsync(endpoint, token, cancellationToken);

    private static async Task<EndpointProbeResult> ProbeCoreAsync(
        ConnectionEndpoint endpoint,
        string token,
        CancellationToken cancellationToken)
    {
        var stopwatch = Stopwatch.StartNew();
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(ProbeTimeout);
            using var client = SecureTransport.CreateClient(endpoint.BaseUrl, endpoint.TlsFingerprint);

            using var healthRequest = new HttpRequestMessage(HttpMethod.Get, "api/health");
            healthRequest.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
            using var healthResponse = await client.SendAsync(healthRequest, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
            if (!healthResponse.IsSuccessStatusCode)
            {
                return new EndpointProbeResult(endpoint, false, stopwatch.Elapsed, $"Health returned HTTP {(int)healthResponse.StatusCode}.");
            }

            await using var healthStream = await healthResponse.Content.ReadAsStreamAsync(timeout.Token);
            using var healthJson = await JsonDocument.ParseAsync(healthStream, cancellationToken: timeout.Token);
            if (!healthJson.RootElement.TryGetProperty("ok", out var ok) || ok.ValueKind != JsonValueKind.True)
            {
                return new EndpointProbeResult(endpoint, false, stopwatch.Elapsed, "Health response did not report ok.");
            }

            using var authRequest = new HttpRequestMessage(HttpMethod.Post, "api/auth/check");
            authRequest.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            authRequest.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
            using var authResponse = await client.SendAsync(authRequest, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
            if (!authResponse.IsSuccessStatusCode)
            {
                var rejected = await CredentialSession.IsStructuredUnauthorizedAsync(authResponse, timeout.Token);
                var reason = rejected
                    ? "The token was rejected."
                    : $"Authentication returned HTTP {(int)authResponse.StatusCode}.";
                return new EndpointProbeResult(endpoint, false, stopwatch.Elapsed, reason, rejected);
            }

            return new EndpointProbeResult(endpoint, true, stopwatch.Elapsed);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return new EndpointProbeResult(endpoint, false, stopwatch.Elapsed, "Connection timed out.");
        }
        catch (ConnectionException error) { return new(endpoint, false, stopwatch.Elapsed, error.Message); }
        catch (HttpRequestException exception)
        {
            return new EndpointProbeResult(endpoint, false, stopwatch.Elapsed, exception.Message);
        }
        catch (JsonException)
        {
            return new EndpointProbeResult(endpoint, false, stopwatch.Elapsed, "Health returned invalid JSON.");
        }
    }
}

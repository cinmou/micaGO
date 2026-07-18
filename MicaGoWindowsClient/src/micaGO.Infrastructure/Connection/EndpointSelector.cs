using System.Diagnostics;
using System.Net.Http.Headers;
using System.Text.Json;
using MicaGo.Core.Connection;

namespace MicaGo.Infrastructure.Connection;

public sealed record EndpointProbeResult(
    ConnectionEndpoint Endpoint,
    bool IsAvailable,
    TimeSpan Latency,
    string? Error = null);

public sealed class EndpointSelector
{
    private static readonly TimeSpan ProbeTimeout = TimeSpan.FromSeconds(6);

    public async Task<EndpointProbeResult> SelectAsync(
        IReadOnlyList<ConnectionEndpoint> endpoints,
        ConnectionMode mode,
        string token,
        CancellationToken cancellationToken = default)
    {
        var lan = endpoints.Where(endpoint => endpoint.Kind == EndpointKind.Lan).ToArray();
        var publicEndpoints = endpoints.Where(endpoint => endpoint.Kind == EndpointKind.Public).ToArray();

        if (mode != ConnectionMode.PublicOnly)
        {
            var selectedLan = await SelectFastestAsync(lan, token, cancellationToken);
            if (selectedLan is not null)
            {
                return selectedLan;
            }
        }

        if (mode != ConnectionMode.LanOnly)
        {
            var selectedPublic = await SelectFastestAsync(publicEndpoints, token, cancellationToken);
            if (selectedPublic is not null)
            {
                return selectedPublic;
            }
        }

        throw new ConnectionException("No advertised endpoint passed both the health and authentication checks.");
    }

    private static async Task<EndpointProbeResult?> SelectFastestAsync(
        IReadOnlyList<ConnectionEndpoint> endpoints,
        string token,
        CancellationToken cancellationToken)
    {
        if (endpoints.Count == 0)
        {
            return null;
        }

        var results = await Task.WhenAll(endpoints.Select(endpoint => ProbeAsync(endpoint, token, cancellationToken)));
        return results
            .Where(result => result.IsAvailable)
            .OrderBy(result => result.Latency)
            .FirstOrDefault();
    }

    private static async Task<EndpointProbeResult> ProbeAsync(
        ConnectionEndpoint endpoint,
        string token,
        CancellationToken cancellationToken)
    {
        var stopwatch = Stopwatch.StartNew();
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(ProbeTimeout);
            using var client = new HttpClient { BaseAddress = new Uri($"{endpoint.BaseUrl}/") };

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
                var reason = authResponse.StatusCode == System.Net.HttpStatusCode.Unauthorized
                    ? "The token was rejected."
                    : $"Authentication returned HTTP {(int)authResponse.StatusCode}.";
                return new EndpointProbeResult(endpoint, false, stopwatch.Elapsed, reason);
            }

            return new EndpointProbeResult(endpoint, true, stopwatch.Elapsed);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return new EndpointProbeResult(endpoint, false, stopwatch.Elapsed, "Connection timed out.");
        }
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

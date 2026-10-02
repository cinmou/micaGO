using System.Net.Http.Json;
using System.Text.Json;
using MicaGo.Core.Connection;
using MicaGo.Infrastructure.Api;
using MicaGo.Infrastructure.Contracts;
using MicaGo.Infrastructure.Storage;

namespace MicaGo.Infrastructure.Connection;

public sealed class ConnectionManager : IDisposable
{
    private readonly IConnectionStore _store;
    private readonly EndpointSelector _selector;
    private readonly object _gate = new();
    private readonly Dictionary<string, RouteProbe> _probes = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _probing = new(StringComparer.OrdinalIgnoreCase);
    private MicaGoApi? _api;
    private string? _token;
    private int _selectionEpoch;
    private readonly SemaphoreSlim _endpointRefreshGate = new(1, 1);

    public ConnectionManager(IConnectionStore store, EndpointSelector selector)
    {
        _store = store;
        _selector = selector;
    }

    public ConnectionProfile? Profile { get; private set; }
    public EndpointProbeResult? ActiveEndpoint { get; private set; }
    public IMicaGoApi? Api => _api;
    public bool IsConnected => _api is not null;
    public event EventHandler? ConnectionChanged;

    /// <summary>
    /// W-UI9: raised on any thread when route checks, the active route, the
    /// switching target or realtime liveness change (Settings route card).
    /// </summary>
    public event EventHandler? RoutesChanged;

    /// <summary>Route a manual switch is currently connecting to.</summary>
    public string? SwitchingRoute { get; private set; }

    /// <summary>Whether the realtime socket is live (set by the realtime loop's status).</summary>
    public bool RealtimeLive { get; private set; }

    /// <summary>Routes in a stable order for Settings.</summary>
    public IReadOnlyList<ConnectionEndpoint> RouteOptions =>
        Profile is { } profile ? RouteSelection.DisplayOrder(profile.Endpoints, profile.Mode) : [];

    public RouteProbe? ProbeFor(string baseUrl)
    {
        lock (_gate) return _probes.GetValueOrDefault(baseUrl);
    }

    public bool IsProbing(string baseUrl)
    {
        lock (_gate) return _probing.Contains(baseUrl);
    }

    public void SetRealtimeLive(bool live)
    {
        if (RealtimeLive == live) return;
        RealtimeLive = live;
        RoutesChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Fast local check (connection file + Credential Manager) — no network.</summary>
    public async Task<bool> HasSavedProfileAsync(CancellationToken cancellationToken = default) =>
        await _store.LoadAsync(cancellationToken) is not null;

    public async Task<bool> TryRestoreAsync(CancellationToken cancellationToken = default)
    {
        var saved = await _store.LoadAsync(cancellationToken);
        if (saved is null || string.IsNullOrEmpty(saved.Profile.DeviceId))
        {
            return false;
        }

        try
        {
            await ActivateAsync(saved.Profile, saved.Token, persist: true, cancellationToken);
            return true;
        }
        catch (ConnectionException)
        {
            DisposeApi();
            Profile = null;
            ActiveEndpoint = null;
            ConnectionChanged?.Invoke(this, EventArgs.Empty);
            return false;
        }
    }

    public async Task ConnectPairingJsonAsync(string pairingJson, CancellationToken cancellationToken = default)
    {
        var payload = PairingPayloadParser.Parse(pairingJson);
        if (payload.Version < 4) throw new ConnectionException("Create a new pairing code in micaGO 0.84 or later on the Mac. Older connection JSON is no longer supported.");
        var initialProfile = new ConnectionProfile(
            payload.ServerName,
            payload.Endpoints[0].BaseUrl,
            payload.Endpoints[0].WebSocketUrl,
            payload.Mode,
            payload.ConfigRevision,
            payload.Endpoints, TlsFingerprint: payload.TlsFingerprint);
        foreach (var endpoint in payload.Endpoints)
        {
            using var client = SecureTransport.CreateClient(endpoint.BaseUrl, endpoint.TlsFingerprint);
            client.Timeout = TimeSpan.FromSeconds(6);
            client.MaxResponseContentBufferSize = 4096;
            try
            {
                using var health = await client.GetAsync("api/health", cancellationToken);
                if (!health.IsSuccessStatusCode) continue;
                using var body = JsonDocument.Parse(await health.Content.ReadAsStringAsync(cancellationToken));
                if (!body.RootElement.TryGetProperty("ok", out var ok) || ok.ValueKind != JsonValueKind.True) continue;
            }
            catch (HttpRequestException) { continue; }
            catch (JsonException) { continue; }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { continue; }
            // Redeem once; an uncertain result requires a fresh invitation.
            using var response = await client.PostAsJsonAsync("api/pairing/redeem", new { pairingCode = payload.PairingCode }, cancellationToken);
            if (!response.IsSuccessStatusCode) throw new ConnectionException("Pairing code expired or already used. Create a new code on the Mac.");
            using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancellationToken));
            var credential = document.RootElement.GetProperty("token").GetString();
            var deviceId = document.RootElement.GetProperty("deviceId").GetString();
            if (credential is null || !System.Text.RegularExpressions.Regex.IsMatch(credential, "\\A[a-f0-9]{64}\\z") || string.IsNullOrEmpty(deviceId))
                throw new ConnectionException("Invalid device credential response.");
            initialProfile = initialProfile with { DeviceId = deviceId };
            await ActivateAsync(initialProfile, credential, persist: true, cancellationToken);
            return;
        }
        throw new ConnectionException("No secure pairing endpoint could be reached.");
    }

    public async Task DisconnectAsync(CancellationToken cancellationToken = default)
    {
        Interlocked.Increment(ref _selectionEpoch);
        DisposeApi();
        Profile = null;
        ActiveEndpoint = null;
        _token = null;
        SwitchingRoute = null;
        RealtimeLive = false;
        lock (_gate)
        {
            _probes.Clear();
            _probing.Clear();
        }
        await _store.ClearAsync(cancellationToken);
        ConnectionChanged?.Invoke(this, EventArgs.Empty);
        RoutesChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>W-UI9: checks every route in parallel for Settings. Never changes the active route.</summary>
    public async Task ProbeRoutesAsync(CancellationToken cancellationToken = default)
    {
        var token = _token;
        var routes = RouteOptions;
        if (token is null || routes.Count == 0) return;
        foreach (var route in routes) MarkProbing(route.BaseUrl);
        await Task.WhenAll(routes.Select(async route =>
        {
            try { Record(await _selector.ProbeAsync(route, token, cancellationToken)); }
            finally { ClearProbing(route.BaseUrl); }
        }));
    }

    /// <summary>
    /// W-UI9: switch to <paramref name="baseUrl"/> now and keep using it until it
    /// can't be reached — then selection is automatic again. The current route
    /// keeps serving until the new one passes health + auth.
    /// </summary>
    public async Task<RouteSwitchResult> SwitchRouteAsync(string baseUrl, CancellationToken cancellationToken = default)
    {
        var profile = Profile;
        var token = _token;
        var target = RouteOptions.FirstOrDefault(route =>
            string.Equals(route.BaseUrl, baseUrl, StringComparison.OrdinalIgnoreCase));
        if (profile is null || token is null || _api is null || target is null) return RouteSwitchResult.Unreachable;

        Profile = profile with { SelectedBaseUrl = target.BaseUrl };
        SwitchingRoute = target.BaseUrl;
        RoutesChanged?.Invoke(this, EventArgs.Empty);
        try
        {
            await _store.SaveAsync(Profile, token, cancellationToken);
            // ReselectCoreAsync already refuses to apply a stale run. Don't compare the
            // epoch again afterwards: the socket cancelled by the switch makes the
            // realtime loop start its own (confirming) reselection right away.
            bool applied;
            try { applied = await ReselectCoreAsync(cancellationToken); }
            catch (ConnectionException) { return RouteSwitchResult.Unreachable; }
            if (!applied) return RouteSwitchResult.Superseded;
            return string.Equals(ActiveEndpoint?.Endpoint.BaseUrl, target.BaseUrl, StringComparison.OrdinalIgnoreCase)
                ? RouteSwitchResult.Switched
                : RouteSwitchResult.FellBack;
        }
        finally
        {
            if (string.Equals(SwitchingRoute, target.BaseUrl, StringComparison.OrdinalIgnoreCase))
            {
                SwitchingRoute = null;
                RoutesChanged?.Invoke(this, EventArgs.Empty);
            }
        }
    }

    /// <summary>
    /// W-UI9: called by the realtime loop before each reconnect. Re-runs route
    /// selection on the live API instance so a dropped route falls back to
    /// another one; failures are left to the loop's backoff.
    /// </summary>
    public async Task ReselectRouteAsync(CancellationToken cancellationToken = default) =>
        await ReselectCoreAsync(cancellationToken);

    /// <returns>False when a newer selection (or a disconnect) superseded this run.</returns>
    private async Task<bool> ReselectCoreAsync(CancellationToken cancellationToken)
    {
        var profile = Profile;
        var token = _token;
        var api = _api;
        var epoch = Interlocked.Increment(ref _selectionEpoch);
        if (profile is null || token is null || api is null) return false;

        var (selected, kept) = await SelectRouteAsync(profile, token, cancellationToken);
        if (epoch != Volatile.Read(ref _selectionEpoch) || !ReferenceEquals(api, _api)) return false;

        var updated = kept with
        {
            ActiveBaseUrl = selected.Endpoint.BaseUrl,
            ActiveWebSocketUrl = selected.Endpoint.WebSocketUrl,
        };
        api.Rebase(selected.Endpoint.BaseUrl, selected.Endpoint.WebSocketUrl, selected.Endpoint.TlsFingerprint);
        Profile = updated;
        ActiveEndpoint = selected;
        await _store.SaveAsync(updated, token, cancellationToken);
        RoutesChanged?.Invoke(this, EventArgs.Empty);
        return true;
    }

    /// <summary>
    /// The chosen route (<see cref="ConnectionProfile.SelectedBaseUrl"/>) is
    /// probed alone first and kept while it passes; otherwise automatic selection
    /// runs over the other routes and, if one connects, the choice is dropped.
    /// When nothing is reachable the choice is kept and the exception propagates.
    /// </summary>
    private async Task<(EndpointProbeResult Selected, ConnectionProfile Profile)> SelectRouteAsync(
        ConnectionProfile profile,
        string token,
        CancellationToken cancellationToken)
    {
        var chosen = string.IsNullOrWhiteSpace(profile.SelectedBaseUrl)
            ? null
            : RouteSelection.DisplayOrder(profile.Endpoints, profile.Mode).FirstOrDefault(route =>
                string.Equals(route.BaseUrl, profile.SelectedBaseUrl, StringComparison.OrdinalIgnoreCase));
        if (chosen is not null)
        {
            MarkProbing(chosen.BaseUrl);
            EndpointProbeResult result;
            try { result = await _selector.ProbeAsync(chosen, token, cancellationToken); }
            finally { ClearProbing(chosen.BaseUrl); }
            Record(result);
            if (result.IsAvailable) return (result, profile);
        }

        var fallback = await _selector.SelectAsync(
            profile.Endpoints,
            profile.Mode,
            token,
            cancellationToken,
            excludeBaseUrl: chosen?.BaseUrl,
            observe: Record);
        return (fallback, chosen is null ? profile : profile with { SelectedBaseUrl = null });
    }

    private async Task ActivateAsync(
        ConnectionProfile profile,
        string token,
        bool persist,
        CancellationToken cancellationToken)
    {
        Interlocked.Increment(ref _selectionEpoch);
        var (selected, kept) = await SelectRouteAsync(profile, token, cancellationToken);
        var activated = kept with
        {
            ActiveBaseUrl = selected.Endpoint.BaseUrl,
            ActiveWebSocketUrl = selected.Endpoint.WebSocketUrl,
        };

        var api = new MicaGoApi(activated.ActiveBaseUrl, activated.ActiveWebSocketUrl, token, selected.Endpoint.TlsFingerprint);
        try
        {
            if (persist)
            {
                await _store.SaveAsync(activated, token, cancellationToken);
            }

            DisposeApi();
            Profile = activated;
            ActiveEndpoint = selected;
            _api = api;
            _token = token;
            ConnectionChanged?.Invoke(this, EventArgs.Empty);
            RoutesChanged?.Invoke(this, EventArgs.Empty);
        }
        catch
        {
            api.Dispose();
            throw;
        }
    }

    public async Task RefreshEndpointsAsync(CancellationToken ct = default)
    {
        await _endpointRefreshGate.WaitAsync(ct);
        try
        {
            var client = _api; var profile = Profile; var token = _token; var epoch = _selectionEpoch;
            if (client is null || profile is null || token is null) return;
            using var document = await client.GetServerUrlsAsync(ct);
            if (!ReferenceEquals(client, _api) || epoch != _selectionEpoch || !ReferenceEquals(profile, Profile)) return;
            var next = EndpointConfiguration.Apply(profile, document.RootElement);
            if (next.ConfigRevision == profile.ConfigRevision && next.SelectedBaseUrl == profile.SelectedBaseUrl && next.ActiveWebSocketUrl == profile.ActiveWebSocketUrl && next.Endpoints.SequenceEqual(profile.Endpoints)) return;
            await _store.SaveAsync(next, token, ct);
            if (!ReferenceEquals(client, _api) || epoch != _selectionEpoch || !ReferenceEquals(profile, Profile))
            {
                if (Profile is { } current && _token is { } currentToken) await _store.SaveAsync(current, currentToken, ct);
                return;
            }
            Profile = next;
            var activePin = next.Endpoints.FirstOrDefault(e => e.BaseUrl == next.ActiveBaseUrl)?.TlsFingerprint
                ?? profile.Endpoints.FirstOrDefault(e => e.BaseUrl == next.ActiveBaseUrl)?.TlsFingerprint;
            client.Rebase(next.ActiveBaseUrl, next.ActiveWebSocketUrl, activePin);
            RoutesChanged?.Invoke(this, EventArgs.Empty);
            if (next.Endpoints.Count > 0 && !next.Endpoints.Any(endpoint => endpoint.BaseUrl.Equals(next.ActiveBaseUrl, StringComparison.OrdinalIgnoreCase)))
                await ReselectRouteAsync(ct);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (OperationCanceledException) { }
        catch (HttpRequestException) { }
        catch (MicaGoApiException) { }
        catch (System.Text.Json.JsonException) { }
        catch (InvalidDataException) { }
        finally { _endpointRefreshGate.Release(); }
    }

    private void MarkProbing(string baseUrl)
    {
        lock (_gate) _probing.Add(baseUrl);
        RoutesChanged?.Invoke(this, EventArgs.Empty);
    }

    private void ClearProbing(string baseUrl)
    {
        lock (_gate) _probing.Remove(baseUrl);
    }

    private void Record(EndpointProbeResult result)
    {
        lock (_gate)
        {
            _probing.Remove(result.Endpoint.BaseUrl);
            _probes[result.Endpoint.BaseUrl] = new RouteProbe(
                result.IsAvailable,
                result.IsAvailable ? result.Latency : null);
        }
        RoutesChanged?.Invoke(this, EventArgs.Empty);
    }

    private void DisposeApi()
    {
        _api?.Dispose();
        _api = null;
    }

    public void Dispose()
    {
        DisposeApi();
    }
}

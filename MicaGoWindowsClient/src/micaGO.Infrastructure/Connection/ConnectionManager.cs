using MicaGo.Core.Connection;
using MicaGo.Infrastructure.Api;
using MicaGo.Infrastructure.Contracts;
using MicaGo.Infrastructure.Storage;

namespace MicaGo.Infrastructure.Connection;

public sealed class ConnectionManager : IDisposable
{
    private readonly IConnectionStore _store;
    private readonly EndpointSelector _selector;

    public ConnectionManager(IConnectionStore store, EndpointSelector selector)
    {
        _store = store;
        _selector = selector;
    }

    public ConnectionProfile? Profile { get; private set; }
    public EndpointProbeResult? ActiveEndpoint { get; private set; }
    public IMicaGoApi? Api { get; private set; }
    public bool IsConnected => Api is not null;

    public async Task<bool> TryRestoreAsync(CancellationToken cancellationToken = default)
    {
        var saved = await _store.LoadAsync(cancellationToken);
        if (saved is null)
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
            return false;
        }
    }

    public async Task ConnectPairingJsonAsync(string pairingJson, CancellationToken cancellationToken = default)
    {
        var payload = PairingPayloadParser.Parse(pairingJson);
        var initialProfile = new ConnectionProfile(
            payload.ServerName,
            payload.Endpoints[0].BaseUrl,
            payload.Endpoints[0].WebSocketUrl,
            payload.Mode,
            payload.ConfigRevision,
            payload.Endpoints);
        await ActivateAsync(initialProfile, payload.Token, persist: true, cancellationToken);
    }

    public async Task DisconnectAsync(CancellationToken cancellationToken = default)
    {
        DisposeApi();
        Profile = null;
        ActiveEndpoint = null;
        await _store.ClearAsync(cancellationToken);
    }

    private async Task ActivateAsync(
        ConnectionProfile profile,
        string token,
        bool persist,
        CancellationToken cancellationToken)
    {
        var selected = await _selector.SelectAsync(profile.Endpoints, profile.Mode, token, cancellationToken);
        var activated = profile with
        {
            ActiveBaseUrl = selected.Endpoint.BaseUrl,
            ActiveWebSocketUrl = selected.Endpoint.WebSocketUrl,
        };

        var api = new MicaGoApi(activated.ActiveBaseUrl, activated.ActiveWebSocketUrl, token);
        try
        {
            if (persist)
            {
                await _store.SaveAsync(activated, token, cancellationToken);
            }

            DisposeApi();
            Profile = activated;
            ActiveEndpoint = selected;
            Api = api;
        }
        catch
        {
            api.Dispose();
            throw;
        }
    }

    private void DisposeApi()
    {
        Api?.Dispose();
        Api = null;
    }

    public void Dispose()
    {
        DisposeApi();
    }
}

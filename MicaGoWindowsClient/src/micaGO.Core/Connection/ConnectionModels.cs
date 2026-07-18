namespace MicaGo.Core.Connection;

public enum ConnectionMode
{
    Auto,
    LanOnly,
    PublicOnly,
    LanFirst,
}

public enum EndpointKind
{
    Lan,
    Public,
    Local,
}

public sealed record ConnectionEndpoint(
    EndpointKind Kind,
    string BaseUrl,
    string WebSocketUrl,
    int Priority = 1);

public sealed record PairingPayload(
    int Version,
    ConnectionMode Mode,
    string Token,
    string? ServerName,
    string ConfigRevision,
    IReadOnlyList<ConnectionEndpoint> Endpoints);

public sealed record ConnectionProfile(
    string? ServerName,
    string ActiveBaseUrl,
    string ActiveWebSocketUrl,
    ConnectionMode Mode,
    string ConfigRevision,
    IReadOnlyList<ConnectionEndpoint> Endpoints);

public sealed record SavedConnection(ConnectionProfile Profile, string Token);

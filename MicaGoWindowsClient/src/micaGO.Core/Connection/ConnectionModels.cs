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
    int Priority = 1,
    string? TlsFingerprint = null);

public sealed record PairingPayload(
    int Version,
    ConnectionMode Mode,
    string Token,
    string? ServerName,
    string ConfigRevision,
    IReadOnlyList<ConnectionEndpoint> Endpoints,
    string? PairingCode = null,
    string? TlsFingerprint = null)
{
    public override string ToString() => $"PairingPayload(version={Version}, credential=<redacted>, endpoints={Endpoints.Count})";
}

public sealed record ConnectionProfile(
    string? ServerName,
    string ActiveBaseUrl,
    string ActiveWebSocketUrl,
    ConnectionMode Mode,
    string ConfigRevision,
    IReadOnlyList<ConnectionEndpoint> Endpoints,
    // W-UI9: the route the user switched to; kept until it can't be reached.
    string? SelectedBaseUrl = null,
    string? DeviceId = null,
    string? TlsFingerprint = null);

public sealed record SavedConnection(ConnectionProfile Profile, string Token)
{
    public override string ToString() => "SavedConnection(credential=<redacted>)";
}

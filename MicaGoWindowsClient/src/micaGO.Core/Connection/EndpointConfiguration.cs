using System.Text.Json;
namespace MicaGo.Core.Connection;

public static class EndpointConfiguration
{
    public static ConnectionProfile Apply(ConnectionProfile profile, JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("lan", out var lan) || lan.ValueKind != JsonValueKind.Array)
            throw new InvalidDataException("Invalid endpoint configuration.");
        var revision = Text(root, "connectionRevision");
        var explicitVisibility = lan.EnumerateArray().Any(row => row.ValueKind == JsonValueKind.Object && (row.TryGetProperty("hidden", out _) || row.TryGetProperty("isHidden", out _) || row.TryGetProperty("disabled", out _) || row.TryGetProperty("enabled", out _)));
        var previousLan = profile.Endpoints.Where(row => row.Kind == EndpointKind.Lan).ToArray();
        var routes = new List<ConnectionEndpoint>();
        foreach (var row in lan.EnumerateArray())
        {
            if (row.ValueKind != JsonValueKind.Object || Flag(row, "hidden", false) || Flag(row, "isHidden", false) || Flag(row, "disabled", false) || !Flag(row, "enabled", true)) continue;
            var endpoint = Parse(row, EndpointKind.Lan);
            if (endpoint is not null) endpoint = endpoint with { TlsFingerprint = profile.TlsFingerprint ?? previousLan.FirstOrDefault(e => !string.IsNullOrEmpty(e.TlsFingerprint))?.TlsFingerprint };
            if (endpoint is null) continue;
            if (!explicitVisibility && previousLan.Length > 0 && !previousLan.Any(old => old.BaseUrl.Equals(endpoint.BaseUrl, StringComparison.OrdinalIgnoreCase))) continue;
            routes.Add(endpoint);
        }
        if (routes.Count == 0 && !explicitVisibility) routes.AddRange(previousLan);
        if (root.TryGetProperty("public", out var pub) && pub.ValueKind == JsonValueKind.Object && Flag(pub, "enabled", false))
        {
            var endpoint = Parse(pub, EndpointKind.Public); if (endpoint is not null) routes.Add(endpoint);
        }
        if (!string.IsNullOrEmpty(profile.DeviceId)) routes.RemoveAll(e => new Uri(e.BaseUrl).Scheme != "https" || new Uri(e.WebSocketUrl).Scheme != "wss" || new Uri(e.BaseUrl).Host != new Uri(e.WebSocketUrl).Host || new Uri(e.BaseUrl).Port != new Uri(e.WebSocketUrl).Port);
        var endpoints = routes.DistinctBy(row => row.BaseUrl, StringComparer.OrdinalIgnoreCase).ToArray();
        var pin = profile.SelectedBaseUrl;
        if (pin is not null && !endpoints.Any(row => row.BaseUrl.Equals(pin, StringComparison.OrdinalIgnoreCase))) pin = null;
        var active = endpoints.FirstOrDefault(row => row.BaseUrl.Equals(profile.ActiveBaseUrl, StringComparison.OrdinalIgnoreCase));
        return profile with { Endpoints = endpoints, ConfigRevision = revision, SelectedBaseUrl = pin, ActiveWebSocketUrl = active?.WebSocketUrl ?? profile.ActiveWebSocketUrl };
    }
    private static ConnectionEndpoint? Parse(JsonElement row, EndpointKind kind)
    {
        var baseUrl = EndpointUrls.NormalizeBaseUrl(Text(row, "baseUrl")); if (baseUrl.Length == 0) return null;
        var ws = EndpointUrls.NormalizeWebSocketUrl(Text(row, "wsUrl"), baseUrl); if (ws.Length == 0) return null;
        return new(kind, baseUrl, ws, kind == EndpointKind.Lan ? 1 : 2);
    }
    private static string Text(JsonElement row, string name) => row.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() ?? "" : "";
    private static bool Flag(JsonElement row, string name, bool fallback) => row.TryGetProperty(name, out var value) ? value.ValueKind switch { JsonValueKind.True => true, JsonValueKind.False => false, JsonValueKind.Number => value.TryGetInt32(out var n) && n != 0, JsonValueKind.String => value.GetString() is "1" or "true", _ => fallback } : fallback;
}

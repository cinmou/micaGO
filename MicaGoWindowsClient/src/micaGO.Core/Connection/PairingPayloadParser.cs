using System.Text.Json;

namespace MicaGo.Core.Connection;

public sealed class PairingPayloadException(string message) : Exception(message);

public static class PairingPayloadParser
{
    public static PairingPayload Parse(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
        {
            throw new PairingPayloadException("The pairing JSON is empty.");
        }

        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(raw);
        }
        catch (JsonException)
        {
            throw new PairingPayloadException("This is not valid micaGO pairing JSON.");
        }

        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                throw new PairingPayloadException("This is not valid micaGO pairing JSON.");
            }

            var token = GetString(root, "token");
            if (string.IsNullOrWhiteSpace(token))
            {
                throw new PairingPayloadException("The pairing JSON is missing its token.");
            }

            var version = GetInt(root, "version") ?? 1;
            return version switch
            {
                >= 3 when TryGetArray(root, "candidates", out var candidates) =>
                    ParseCandidates(root, version, token, candidates, ConnectionMode.LanFirst),
                >= 2 when TryGetArray(root, "endpoints", out var endpoints) =>
                    ParseCandidates(root, version, token, endpoints, ParseMode(GetString(root, "mode"))),
                _ => ParseLegacy(root, token),
            };
        }
    }

    private static PairingPayload ParseLegacy(JsonElement root, string token)
    {
        var baseUrl = EndpointUrls.NormalizeBaseUrl(GetString(root, "baseUrl") ?? string.Empty);
        if (baseUrl.Length == 0)
        {
            throw new PairingPayloadException("The pairing JSON is missing a valid HTTP server URL.");
        }

        var websocket = EndpointUrls.NormalizeWebSocketUrl(GetString(root, "websocketUrl"), baseUrl);
        if (websocket.Length == 0)
        {
            throw new PairingPayloadException("The WebSocket URL must use ws or wss.");
        }

        return new PairingPayload(
            1,
            ConnectionMode.Auto,
            token,
            GetString(root, "serverName"),
            string.Empty,
            [new ConnectionEndpoint(EndpointKind.Lan, baseUrl, websocket)]);
    }

    private static PairingPayload ParseCandidates(
        JsonElement root,
        int version,
        string token,
        JsonElement candidates,
        ConnectionMode mode)
    {
        var parsed = new List<ConnectionEndpoint>();
        foreach (var candidate in candidates.EnumerateArray())
        {
            if (candidate.ValueKind != JsonValueKind.Object || IsHidden(candidate))
            {
                continue;
            }

            var kind = ParseKind(GetString(candidate, "kind"));
            if (kind == EndpointKind.Local)
            {
                continue;
            }

            var baseUrl = EndpointUrls.NormalizeBaseUrl(GetString(candidate, "baseUrl") ?? string.Empty);
            if (baseUrl.Length == 0)
            {
                continue;
            }

            var websocket = EndpointUrls.NormalizeWebSocketUrl(GetString(candidate, "wsUrl"), baseUrl);
            if (websocket.Length == 0)
            {
                throw new PairingPayloadException("A WebSocket URL must use ws or wss.");
            }

            parsed.Add(new ConnectionEndpoint(
                kind,
                baseUrl,
                websocket,
                GetInt(candidate, "priority") ?? 1));
        }

        var usable = parsed
            .Where(endpoint => mode != ConnectionMode.LanOnly || endpoint.Kind == EndpointKind.Lan)
            .DistinctBy(endpoint => endpoint.BaseUrl, StringComparer.OrdinalIgnoreCase)
            .OrderBy(endpoint => endpoint.Priority)
            .ToArray();
        if (usable.Length == 0)
        {
            throw new PairingPayloadException("The pairing JSON has no usable LAN or public endpoint.");
        }

        return new PairingPayload(
            version,
            mode == ConnectionMode.Auto && version >= 2 ? ConnectionMode.LanFirst : mode,
            token,
            GetString(root, "serverName"),
            GetString(root, "configRevision") ?? string.Empty,
            usable);
    }

    private static bool IsHidden(JsonElement candidate) =>
        GetBoolean(candidate, "hidden") ||
        GetBoolean(candidate, "isHidden") ||
        GetBoolean(candidate, "disabled") ||
        (candidate.TryGetProperty("enabled", out _) && !GetBoolean(candidate, "enabled"));

    private static ConnectionMode ParseMode(string? value) => value?.Trim() switch
    {
        "lan_only" or "lanOnly" => ConnectionMode.LanOnly,
        "public_only" or "publicOnly" => ConnectionMode.PublicOnly,
        "lan_first" or "lanFirst" => ConnectionMode.LanFirst,
        _ => ConnectionMode.Auto,
    };

    private static EndpointKind ParseKind(string? value) => value?.Trim() switch
    {
        "lan" => EndpointKind.Lan,
        "public" => EndpointKind.Public,
        _ => EndpointKind.Local,
    };

    private static bool TryGetArray(JsonElement element, string name, out JsonElement array)
    {
        if (element.TryGetProperty(name, out array) && array.ValueKind == JsonValueKind.Array)
        {
            return true;
        }

        array = default;
        return false;
    }

    private static string? GetString(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()?.Trim()
            : null;

    private static int? GetInt(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.TryGetInt32(out var result)
            ? result
            : null;

    private static bool GetBoolean(JsonElement element, string name)
    {
        if (!element.TryGetProperty(name, out var value))
        {
            return false;
        }

        return value.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.Number when value.TryGetInt32(out var number) => number != 0,
            JsonValueKind.String => value.GetString()?.Trim().ToLowerInvariant() is "true" or "1" or "yes",
            _ => false,
        };
    }
}

namespace MicaGo.Core.Connection;

public static class EndpointUrls
{
    public static string NormalizeBaseUrl(string value)
    {
        var candidate = value.Trim();
        if (candidate.Length == 0)
        {
            return string.Empty;
        }

        if (!candidate.Contains("://", StringComparison.Ordinal))
        {
            candidate = $"http://{candidate}";
        }

        if (!Uri.TryCreate(candidate, UriKind.Absolute, out var uri) ||
            (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps) ||
            string.IsNullOrWhiteSpace(uri.Host))
        {
            return string.Empty;
        }

        var builder = new UriBuilder(uri.Scheme, uri.Host, uri.IsDefaultPort ? -1 : uri.Port)
        {
            Path = string.Empty,
            Query = string.Empty,
            Fragment = string.Empty,
        };
        return builder.Uri.GetLeftPart(UriPartial.Authority);
    }

    public static string DeriveWebSocketUrl(string baseUrl)
    {
        var normalized = NormalizeBaseUrl(baseUrl);
        if (!Uri.TryCreate(normalized, UriKind.Absolute, out var uri))
        {
            return string.Empty;
        }

        var builder = new UriBuilder(uri)
        {
            Scheme = uri.Scheme == Uri.UriSchemeHttps ? "wss" : "ws",
            Port = uri.IsDefaultPort ? -1 : uri.Port,
            Path = "/ws",
            Query = string.Empty,
            Fragment = string.Empty,
        };
        return builder.Uri.ToString().TrimEnd('/');
    }

    public static string NormalizeWebSocketUrl(string? value, string baseUrl)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return DeriveWebSocketUrl(baseUrl);
        }

        if (!Uri.TryCreate(value.Trim(), UriKind.Absolute, out var uri) ||
            (uri.Scheme != "ws" && uri.Scheme != "wss") ||
            string.IsNullOrWhiteSpace(uri.Host))
        {
            return string.Empty;
        }

        return uri.ToString().TrimEnd('/');
    }
}

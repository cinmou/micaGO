using System.Net;
using System.Text.RegularExpressions;

namespace MicaGo.Core.Models;

public sealed record LinkPreviewMetadata(
    string Url,
    string? Title = null,
    string? Description = null,
    string? ImageUrl = null,
    string? SiteName = null)
{
    public string Host => Uri.TryCreate(Url, UriKind.Absolute, out var uri)
        ? uri.Host.StartsWith("www.", StringComparison.OrdinalIgnoreCase) ? uri.Host[4..] : uri.Host
        : Url;

    public bool HasDisplayContent =>
        !string.IsNullOrWhiteSpace(Title) ||
        !string.IsNullOrWhiteSpace(Description) ||
        !string.IsNullOrWhiteSpace(ImageUrl) ||
        !string.IsNullOrWhiteSpace(SiteName);
}

/// <summary>Flutter-compatible URL extraction and lightweight social metadata parsing.</summary>
public static partial class LinkPreviewSemantics
{
    public static IReadOnlyList<string> UrlsInText(string text) => UrlRegex().Matches(text)
        .Select(match => NormalizeUrl(match.Value))
        .Where(url => url is not null)
        .Cast<string>()
        .ToArray();

    public static string? NormalizeUrl(string raw)
    {
        var value = TrailingPunctuation().Replace(raw.Trim(), string.Empty);
        if (!value.StartsWith("http://", StringComparison.OrdinalIgnoreCase) &&
            !value.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
        {
            value = "https://" + value;
        }
        return Uri.TryCreate(value, UriKind.Absolute, out var uri) &&
               (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps) &&
               !string.IsNullOrWhiteSpace(uri.Host)
            ? uri.AbsoluteUri
            : null;
    }

    public static LinkPreviewMetadata ParseHtml(string url, string html)
    {
        var metadata = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (Match tag in MetaTag().Matches(html))
        {
            var attributes = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (Match attribute in HtmlAttribute().Matches(tag.Value))
            {
                var value = attribute.Groups["double"].Success ? attribute.Groups["double"].Value
                    : attribute.Groups["single"].Success ? attribute.Groups["single"].Value
                    : attribute.Groups["bare"].Value;
                attributes[attribute.Groups["name"].Value] = Clean(value);
            }
            if (!attributes.TryGetValue("content", out var content) || string.IsNullOrWhiteSpace(content)) continue;
            if (attributes.TryGetValue("property", out var property)) metadata[property] = content;
            if (attributes.TryGetValue("name", out var name)) metadata[name] = content;
        }

        string? Read(params string[] keys) => keys.Select(key => metadata.GetValueOrDefault(key)).FirstOrDefault(value => !string.IsNullOrWhiteSpace(value));
        var titleMatch = HtmlTitle().Match(html);
        var title = Read("og:title", "twitter:title") ?? (titleMatch.Success ? Clean(titleMatch.Groups["value"].Value) : null);
        var image = ResolveUrl(url, Read("og:image", "twitter:image"));
        return new LinkPreviewMetadata(
            url,
            EmptyToNull(title),
            EmptyToNull(Read("og:description", "description", "twitter:description")),
            image,
            EmptyToNull(Read("og:site_name")));
    }

    private static string? ResolveUrl(string baseUrl, string? value)
    {
        if (string.IsNullOrWhiteSpace(value) || !Uri.TryCreate(baseUrl, UriKind.Absolute, out var baseUri)) return null;
        return Uri.TryCreate(baseUri, value, out var resolved) &&
               (resolved.Scheme == Uri.UriSchemeHttp || resolved.Scheme == Uri.UriSchemeHttps)
            ? resolved.AbsoluteUri
            : null;
    }

    private static string Clean(string value) => WebUtility.HtmlDecode(Tag().Replace(value, string.Empty)).Trim();
    private static string? EmptyToNull(string? value) => string.IsNullOrWhiteSpace(value) ? null : value;

    [GeneratedRegex(@"(?:(?:https?://)|(?:www\.))[^\s<>()]+", RegexOptions.IgnoreCase)]
    private static partial Regex UrlRegex();
    [GeneratedRegex(@"[.,!?;:]+$")]
    private static partial Regex TrailingPunctuation();
    [GeneratedRegex(@"<meta\b[^>]*>", RegexOptions.IgnoreCase)]
    private static partial Regex MetaTag();
    [GeneratedRegex("(?<name>[\\w:-]+)\\s*=\\s*(?:\"(?<double>[^\"]*)\"|'(?<single>[^']*)'|(?<bare>[^\\s>]+))", RegexOptions.IgnoreCase)]
    private static partial Regex HtmlAttribute();
    [GeneratedRegex(@"<title\b[^>]*>(?<value>.*?)</title>", RegexOptions.IgnoreCase | RegexOptions.Singleline)]
    private static partial Regex HtmlTitle();
    [GeneratedRegex(@"<[^>]+>")]
    private static partial Regex Tag();
}

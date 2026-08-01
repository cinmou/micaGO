using System.Text.Json;

namespace MicaGo.Core.Models;

/// <summary>Outcome of an update check against the project's GitHub releases.</summary>
public enum UpdateCheckStatus { Idle, Checking, UpToDate, UpdateAvailable, Unknown }

/// <param name="Status">What the check concluded.</param>
/// <param name="LatestVersion">Newest published version (no leading "v"), when known.</param>
/// <param name="ReleaseUrl">Where to send the user to get it.</param>
public sealed record UpdateCheckResult(
    UpdateCheckStatus Status,
    string? LatestVersion = null,
    string ReleaseUrl = UpdateCheck.ReleasesPage)
{
    public static readonly UpdateCheckResult Unknown = new(UpdateCheckStatus.Unknown);
}

/// <summary>
/// C74: "is there a newer build?" against the project's GitHub releases.
///
/// Read-only and unauthenticated. Nothing is downloaded or installed — the UI
/// links to the release page and the user decides. Every failure resolves to
/// <see cref="UpdateCheckResult.Unknown"/>, so an offline or rate-limited check
/// never blocks the app or raises a false alarm.
/// </summary>
public static class UpdateCheck
{
    public const string ReleasesApi = "https://api.github.com/repos/cinmou/MicaGo/releases/latest";
    public const string ReleasesPage = "https://github.com/cinmou/MicaGo/releases/latest";

    /// <summary>
    /// Splits a version into comparable numeric parts, ignoring a leading "v"
    /// and any pre-release suffix ("0.65.0-beta.1" → [0, 65, 0]).
    /// </summary>
    public static int[] VersionParts(string raw)
    {
        var value = raw.Trim();
        while (value.Length > 0 && (value[0] == 'v' || value[0] == 'V')) value = value[1..];
        var cut = value.IndexOfAny(['-', '+', ' ']);
        if (cut > 0) value = value[..cut];
        return value.Split('.', StringSplitOptions.RemoveEmptyEntries)
            .Select(part => int.TryParse(new string(part.Where(char.IsDigit).ToArray()), out var number) ? number : 0)
            .ToArray();
    }

    /// <summary>
    /// True when <paramref name="latest"/> is strictly newer. Missing trailing
    /// parts count as 0, so "0.65" == "0.65.0".
    /// </summary>
    public static bool IsNewer(string latest, string current)
    {
        var a = VersionParts(latest);
        var b = VersionParts(current);
        for (var index = 0; index < Math.Max(a.Length, b.Length); index++)
        {
            var left = index < a.Length ? a[index] : 0;
            var right = index < b.Length ? b[index] : 0;
            if (left != right) return left > right;
        }
        return false;
    }

    /// <summary>Pure: turns a releases-API body into a result (no I/O).</summary>
    public static UpdateCheckResult FromReleaseJson(string body, string currentVersion)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return UpdateCheckResult.Unknown;
            if (root.TryGetProperty("draft", out var draft) && draft.ValueKind == JsonValueKind.True)
                return UpdateCheckResult.Unknown;
            if (!root.TryGetProperty("tag_name", out var tagElement)) return UpdateCheckResult.Unknown;
            var tag = tagElement.GetString()?.Trim();
            if (string.IsNullOrEmpty(tag)) return UpdateCheckResult.Unknown;

            var url = root.TryGetProperty("html_url", out var urlElement) ? urlElement.GetString() : null;
            var version = tag.TrimStart('v', 'V');
            return new UpdateCheckResult(
                IsNewer(tag, currentVersion) ? UpdateCheckStatus.UpdateAvailable : UpdateCheckStatus.UpToDate,
                version,
                string.IsNullOrWhiteSpace(url) ? ReleasesPage : url);
        }
        catch
        {
            return UpdateCheckResult.Unknown;
        }
    }

    /// <summary>Asks GitHub for the newest release. Never throws.</summary>
    public static async Task<UpdateCheckResult> FetchAsync(
        HttpClient client,
        string currentVersion,
        CancellationToken cancellationToken = default)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, ReleasesApi);
            request.Headers.TryAddWithoutValidation("Accept", "application/vnd.github+json");
            request.Headers.TryAddWithoutValidation("X-GitHub-Api-Version", "2022-11-28");
            request.Headers.TryAddWithoutValidation("User-Agent", "micaGO-windows");
            using var response = await client.SendAsync(request, cancellationToken);
            if (!response.IsSuccessStatusCode) return UpdateCheckResult.Unknown;
            return FromReleaseJson(await response.Content.ReadAsStringAsync(cancellationToken), currentVersion);
        }
        catch
        {
            return UpdateCheckResult.Unknown;
        }
    }
}

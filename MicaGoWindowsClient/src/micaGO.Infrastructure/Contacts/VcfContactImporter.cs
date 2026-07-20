using System.Text;
using System.Security.Cryptography;
using MicaGo.Core.Models;
using MicaGo.Infrastructure.Storage;

namespace MicaGo.Infrastructure.Contacts;

public sealed record VcfContactCard(string DisplayName, IReadOnlyList<string> Identities, byte[]? PhotoBytes = null, string? PhotoMimeType = null);
public sealed record VcfContactImportResult(int ContactCount, int IdentityCount, int SkippedCards);

public sealed class VcfContactImporter(LocalCacheStore cache)
{
    private static readonly string AvatarDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "micaGO", "contact_avatars");

    public async Task<VcfContactImportResult> ImportAsync(string path, CancellationToken cancellationToken = default)
    {
        var text = await File.ReadAllTextAsync(path, Encoding.UTF8, cancellationToken);
        var cards = Parse(text);
        if (cards.Count == 0) throw new InvalidDataException("No valid vCard entries were found.");

        var contacts = new Dictionary<string, ContactMatch>(StringComparer.OrdinalIgnoreCase);
        var skipped = 0;
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        foreach (var card in cards)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var identities = card.Identities.Where(IsUsableIdentity).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
            if (identities.Length == 0) { skipped++; continue; }
            var displayName = string.IsNullOrWhiteSpace(card.DisplayName) ? identities[0] : card.DisplayName.Trim();
            var avatarPath = await SavePhotoAsync(card.PhotoBytes, card.PhotoMimeType, cancellationToken);
            foreach (var identity in identities) contacts[identity] = new ContactMatch(identity, displayName, avatarPath, "vcf", now);
        }
        if (contacts.Count == 0) throw new InvalidDataException("The vCard file contains no usable phone numbers or email addresses.");

        // Imports are additive so users can select several address books. A
        // repeated identity is updated by the newest card without disturbing
        // unrelated contacts imported from earlier files.
        await cache.UpsertContactsAsync(contacts.Values, cancellationToken);
        await cache.SetSettingAsync("contacts.vcf.lastImport", now.ToString(), cancellationToken);
        return new(cards.Count - skipped, contacts.Count, skipped);
    }

    public async Task ClearAllAsync(CancellationToken cancellationToken = default)
    {
        await cache.ClearImportedContactsAsync(cancellationToken);
        if (!Directory.Exists(AvatarDirectory)) return;
        foreach (var path in Directory.EnumerateFiles(AvatarDirectory))
        {
            cancellationToken.ThrowIfCancellationRequested();
            try { File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    public static IReadOnlyList<VcfContactCard> Parse(string text)
    {
        var lines = Unfold(text);
        var result = new List<VcfContactCard>();
        List<(string Name, string Parameters, string Value)>? properties = null;
        foreach (var line in lines)
        {
            if (line.Equals("BEGIN:VCARD", StringComparison.OrdinalIgnoreCase)) { properties = []; continue; }
            if (line.Equals("END:VCARD", StringComparison.OrdinalIgnoreCase))
            {
                if (properties is not null) result.Add(ToCard(properties));
                properties = null;
                continue;
            }
            if (properties is null) continue;
            var colon = line.IndexOf(':');
            if (colon <= 0) continue;
            var descriptor = line[..colon];
            var semicolon = descriptor.IndexOf(';');
            var rawName = semicolon < 0 ? descriptor : descriptor[..semicolon];
            var name = rawName[(rawName.LastIndexOf('.') + 1)..].ToUpperInvariant();
            var parameters = semicolon < 0 ? string.Empty : descriptor[(semicolon + 1)..];
            properties.Add((name, parameters, Decode(line[(colon + 1)..], parameters)));
        }
        return result;
    }

    private static VcfContactCard ToCard(IEnumerable<(string Name, string Parameters, string Value)> properties)
    {
        var rows = properties.ToArray();
        var displayName = rows.FirstOrDefault(row => row.Name == "FN").Value;
        if (string.IsNullOrWhiteSpace(displayName))
        {
            var parts = SplitEscaped(rows.FirstOrDefault(row => row.Name == "N").Value, ';').ToArray();
            string Part(int index) => index < parts.Length ? parts[index] : string.Empty;
            displayName = string.Join(" ", new[] { Part(3), Part(1), Part(2), Part(0), Part(4) }.Where(value => !string.IsNullOrWhiteSpace(value)));
        }
        var identities = rows.Where(row => row.Name is "TEL" or "EMAIL")
            .Select(row => row.Value.Trim())
            .Select(value => value.StartsWith("tel:", StringComparison.OrdinalIgnoreCase) ? value[4..] : value.StartsWith("mailto:", StringComparison.OrdinalIgnoreCase) ? value[7..] : value)
            .Where(value => !string.IsNullOrWhiteSpace(value)).ToArray();
        var photo = DecodePhoto(rows.FirstOrDefault(row => row.Name == "PHOTO"));
        return new(Unescape(displayName ?? string.Empty), identities.Select(Unescape).ToArray(), photo.Bytes, photo.MimeType);
    }

    private static (byte[]? Bytes, string? MimeType) DecodePhoto((string Name, string Parameters, string Value) row)
    {
        if (string.IsNullOrWhiteSpace(row.Value)) return (null, null);
        var value = row.Value.Trim();
        string? mimeType = null;
        if (value.StartsWith("data:", StringComparison.OrdinalIgnoreCase))
        {
            var comma = value.IndexOf(',');
            if (comma <= 5 || !value[..comma].Contains(";base64", StringComparison.OrdinalIgnoreCase)) return (null, null);
            mimeType = value[5..comma].Split(';')[0];
            value = value[(comma + 1)..];
        }
        else
        {
            var type = row.Parameters.Split(';', StringSplitOptions.RemoveEmptyEntries)
                .FirstOrDefault(part => part.StartsWith("TYPE=", StringComparison.OrdinalIgnoreCase) || part.StartsWith("MEDIATYPE=", StringComparison.OrdinalIgnoreCase));
            if (type is not null)
            {
                var raw = type[(type.IndexOf('=') + 1)..].Trim('"');
                mimeType = raw.Contains('/') ? raw : "image/" + raw.ToLowerInvariant().Replace("jpg", "jpeg");
            }
        }
        try { return (Convert.FromBase64String(string.Concat(value.Where(ch => !char.IsWhiteSpace(ch)))), mimeType); }
        catch (FormatException) { return (null, null); }
    }

    private static async Task<string?> SavePhotoAsync(byte[]? bytes, string? mimeType, CancellationToken cancellationToken)
    {
        if (bytes is not { Length: > 0 }) return null;
        Directory.CreateDirectory(AvatarDirectory);
        var extension = mimeType?.ToLowerInvariant() switch
        {
            "image/png" => ".png",
            "image/gif" => ".gif",
            "image/webp" => ".webp",
            _ => ".jpg",
        };
        var path = Path.Combine(AvatarDirectory, Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant() + extension);
        if (!File.Exists(path)) await File.WriteAllBytesAsync(path, bytes, cancellationToken);
        return path;
    }

    private static IReadOnlyList<string> Unfold(string text)
    {
        var result = new List<string>();
        foreach (var raw in text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n'))
        {
            if (raw.Length > 0 && (raw[0] == ' ' || raw[0] == '\t') && result.Count > 0) result[^1] += raw[1..];
            else result.Add(raw);
        }
        return result;
    }

    private static string Decode(string value, string parameters)
    {
        if (!parameters.Contains("QUOTED-PRINTABLE", StringComparison.OrdinalIgnoreCase)) return value;
        using var bytes = new MemoryStream();
        for (var i = 0; i < value.Length; i++)
        {
            if (value[i] == '=' && i + 2 < value.Length && byte.TryParse(value.AsSpan(i + 1, 2), System.Globalization.NumberStyles.HexNumber, null, out var parsed)) { bytes.WriteByte(parsed); i += 2; }
            else bytes.WriteByte((byte)value[i]);
        }
        return Encoding.UTF8.GetString(bytes.ToArray());
    }

    private static IEnumerable<string> SplitEscaped(string value, char separator)
    {
        var field = new StringBuilder(); var escaped = false;
        foreach (var ch in value ?? string.Empty)
        {
            if (escaped) { field.Append('\\').Append(ch); escaped = false; }
            else if (ch == '\\') escaped = true;
            else if (ch == separator) { yield return Unescape(field.ToString()); field.Clear(); }
            else field.Append(ch);
        }
        yield return Unescape(field.ToString());
    }

    private static string Unescape(string value) => value.Replace("\\n", "\n", StringComparison.OrdinalIgnoreCase).Replace("\\,", ",").Replace("\\;", ";").Replace("\\\\", "\\");
    private static bool IsUsableIdentity(string value) => value.Contains('@') || value.Count(char.IsDigit) >= 5;
}

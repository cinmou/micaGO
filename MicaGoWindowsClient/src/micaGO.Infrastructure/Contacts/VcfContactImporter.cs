using System.Security.Cryptography;
using System.Text;
using FolkerKinzel.VCards;
using MicaGo.Core.Models;
using MicaGo.Infrastructure.Storage;

namespace MicaGo.Infrastructure.Contacts;

public sealed record VcfContactCard(string DisplayName, IReadOnlyList<string> Identities, byte[]? PhotoBytes = null, string? PhotoMimeType = null, string? StableId = null);
public sealed record VcfContactImportResult(int ContactCount, int IdentityCount, int SkippedCards);

public sealed class VcfContactImporter(LocalCacheStore cache)
{
    private static readonly string AvatarDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "micaGO", "contact_avatars");

    public async Task<VcfContactImportResult> ImportAsync(string path, CancellationToken cancellationToken = default)
    {
        var cards = Vcf.Load(path).Select(ToCard).ToArray();
        if (cards.Length == 0) throw new InvalidDataException("No valid vCard entries were found.");
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
            var contactId = await ResolveContactIdAsync(card.StableId, identities, cancellationToken);
            foreach (var identity in identities) contacts[identity] = new ContactMatch(identity, displayName, avatarPath, "vcf", now, contactId);
        }
        if (contacts.Count == 0) throw new InvalidDataException("The vCard file contains no usable phone numbers or email addresses.");
        await cache.UpsertContactsAsync(contacts.Values, cancellationToken);
        await cache.SetSettingAsync("contacts.vcf.lastImport", now.ToString(), cancellationToken);
        return new(cards.Length - skipped, contacts.Count, skipped);
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
        using var stream = new MemoryStream(Encoding.UTF8.GetBytes(text));
        return Vcf.Deserialize(stream, Encoding.UTF8, false).Select(ToCard).ToArray();
    }

    private async Task<string> ResolveContactIdAsync(string? vCardId, IReadOnlyList<string> identities, CancellationToken cancellationToken)
    {
        if (!string.IsNullOrWhiteSpace(vCardId)) return "vcf:" + Hash(vCardId.Trim());
        foreach (var identity in identities)
        {
            var existing = await cache.ResolveContactAsync(identity, cancellationToken);
            if (!string.IsNullOrWhiteSpace(existing?.ContactId)) return existing.ContactId;
        }
        return "vcf:" + Guid.NewGuid().ToString("N");
    }

    private static VcfContactCard ToCard(VCard card)
    {
        var displayName = card.DisplayNames?.FirstOrDefault(row => row is not null && !row.IsEmpty)?.Value;
        if (string.IsNullOrWhiteSpace(displayName))
        {
            var name = card.NameViews?.FirstOrDefault(row => row is not null && !row.IsEmpty)?.Value;
            if (name is not null) displayName = string.Join(" ", name.Prefixes.Concat(name.Given).Concat(name.Given2).Concat(name.Surnames).Concat(name.Suffixes).Where(value => !string.IsNullOrWhiteSpace(value)));
        }
        var identities = (card.EMails ?? []).Concat(card.Phones ?? [])
            .Where(row => row is not null && !row.IsEmpty).Select(row => StripUriPrefix(row!.Value.Trim()))
            .Where(value => !string.IsNullOrWhiteSpace(value)).ToArray();
        var photoProperty = card.Photos?.FirstOrDefault(row => row is not null && !row.IsEmpty);
        var photo = photoProperty?.Value;
        var photoMimeType = photo?.MediaType;
        if (string.Equals(photoMimeType, "application/octet-stream", StringComparison.OrdinalIgnoreCase))
            photoMimeType = photoProperty?.Parameters.MediaType ?? photoMimeType;
        var stableId = card.ContactID?.Value.Guid?.ToString("D") ?? card.ContactID?.Value.Uri?.AbsoluteUri ?? card.ContactID?.Value.String;
        return new(displayName ?? string.Empty, identities, photo?.Bytes, photoMimeType, stableId);
    }

    private static string StripUriPrefix(string value) => value.StartsWith("tel:", StringComparison.OrdinalIgnoreCase) ? value[4..] : value.StartsWith("mailto:", StringComparison.OrdinalIgnoreCase) ? value[7..] : value;

    private static async Task<string?> SavePhotoAsync(byte[]? bytes, string? mimeType, CancellationToken cancellationToken)
    {
        if (bytes is not { Length: > 0 }) return null;
        Directory.CreateDirectory(AvatarDirectory);
        var extension = mimeType?.ToLowerInvariant() switch { "image/png" => ".png", "image/gif" => ".gif", "image/webp" => ".webp", _ => ".jpg" };
        var path = Path.Combine(AvatarDirectory, Hash(bytes) + extension);
        if (!File.Exists(path)) await File.WriteAllBytesAsync(path, bytes, cancellationToken);
        return path;
    }

    private static string Hash(string value) => Hash(Encoding.UTF8.GetBytes(value));
    private static string Hash(byte[] value) => Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
    private static bool IsUsableIdentity(string value) => value.Contains('@') || value.Count(char.IsDigit) >= 5;
}

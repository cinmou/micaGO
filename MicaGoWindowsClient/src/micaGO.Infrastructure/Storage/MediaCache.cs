using MicaGo.Infrastructure.Contracts;

namespace MicaGo.Infrastructure.Storage;

public sealed class MediaCache
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    public MediaCache(string? root = null)
    {
        Root = root ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "micaGO", "media_cache", "v1");
        Directory.CreateDirectory(Root);
    }
    public string Root { get; }

    public string? TryGetPath(string attachmentId, bool preview = false, bool playable = false)
    {
        var suffix = playable ? ".playable" : preview ? ".preview" : ".original";
        var safe = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(attachmentId))).ToLowerInvariant();
        var path = Path.Combine(Root, safe + suffix);
        if (File.Exists(path)) return path;
        if (preview)
        {
            var original = Path.Combine(Root, safe + ".original");
            if (File.Exists(original)) return original;
        }
        return null;
    }

    public async Task<string> GetAsync(IMicaGoApi api, string attachmentId, bool preview = false, bool playable = false, CancellationToken cancellationToken = default)
    {
        var suffix = playable ? ".playable" : preview ? ".preview" : ".original";
        var safe = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(attachmentId))).ToLowerInvariant();
        var path = Path.Combine(Root, safe + suffix);
        if (TryGetPath(attachmentId, preview, playable) is { } hit) return hit;
        await _gate.WaitAsync(cancellationToken);
        try
        {
            if (File.Exists(path)) return path;
            var bytes = await api.GetAttachmentBytesAsync(attachmentId, preview, playable, cancellationToken);
            var part = path + "." + Guid.NewGuid().ToString("N") + ".part";
            await File.WriteAllBytesAsync(part, bytes, cancellationToken);
            File.Move(part, path, true);
            return path;
        }
        finally { _gate.Release(); }
    }

    public async Task SeedAsync(string attachmentId, string sourcePath, CancellationToken cancellationToken = default)
    {
        var safe = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(attachmentId))).ToLowerInvariant();
        var path = Path.Combine(Root, safe + ".original");
        await using var source = File.OpenRead(sourcePath); await using var destination = File.Create(path); await source.CopyToAsync(destination, cancellationToken);
    }

    public async Task ClearAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            foreach (var file in Directory.EnumerateFiles(Root))
            {
                cancellationToken.ThrowIfCancellationRequested();
                File.Delete(file);
            }
        }
        finally { _gate.Release(); }
    }
}

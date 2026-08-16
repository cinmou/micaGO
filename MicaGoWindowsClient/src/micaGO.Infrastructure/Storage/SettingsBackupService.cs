using System.IO.Compression;
using System.Text.Json;

namespace MicaGo.Infrastructure.Storage;

public sealed record BackupSummary(int SettingCount, bool HasChatBackground, string AppVersion);

/// <summary>
/// Windows settings backup (.micagobak): a plain zip carrying manifest.json,
/// settings.json (the SQLite settings table) and the chat-background asset.
/// The connection profile and token live in Windows Credential Manager and are
/// deliberately never part of the archive; device-specific keys (delta cursor)
/// are excluded so a restored install re-syncs cleanly.
/// </summary>
public sealed class SettingsBackupService(LocalCacheStore cache)
{
    private const string ManifestName = "manifest.json";
    private const string SettingsName = "settings.json";
    private const string HiddenMessagesName = "hidden-messages.json";
    private const string HiddenChatsName = "hidden-chats.json";
    private const string BackgroundEntryPrefix = "assets/chat-background";
    private const string FormatId = "micagobak-win";
    private const int FormatVersion = 1;
    private static readonly string[] ExcludedKeys = ["sync.cursor"];
    private const string BackgroundKey = "appearance.chatBackground";

    public async Task<BackupSummary> ExportAsync(string destinationPath, string appVersion, CancellationToken cancellationToken = default)
    {
        var settings = (await cache.GetAllSettingsAsync(cancellationToken))
            .Where(pair => !ExcludedKeys.Contains(pair.Key))
            .ToDictionary(pair => pair.Key, pair => pair.Value);

        var backgroundPath = settings.GetValueOrDefault(BackgroundKey);
        var hasBackground = !string.IsNullOrWhiteSpace(backgroundPath) && File.Exists(backgroundPath);

        var temp = destinationPath + "." + Guid.NewGuid().ToString("N") + ".part";
        try
        {
            using (var archive = ZipFile.Open(temp, ZipArchiveMode.Create))
            {
                var manifest = new Dictionary<string, object>
                {
                    ["format"] = FormatId,
                    ["version"] = FormatVersion,
                    ["appVersion"] = appVersion,
                    ["exportedAt"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                };
                await WriteEntryAsync(archive, ManifestName, JsonSerializer.Serialize(manifest), cancellationToken);
                await WriteEntryAsync(archive, SettingsName, JsonSerializer.Serialize(settings), cancellationToken);
                await WriteEntryAsync(archive,HiddenMessagesName,JsonSerializer.Serialize(await cache.GetHiddenMessageKeysAsync(cancellationToken)),cancellationToken);
                await WriteEntryAsync(archive,HiddenChatsName,JsonSerializer.Serialize(await cache.GetHiddenChatGuidsAsync(cancellationToken)),cancellationToken);
                if (hasBackground)
                {
                    archive.CreateEntryFromFile(backgroundPath!, BackgroundEntryPrefix + Path.GetExtension(backgroundPath));
                }
            }
            File.Move(temp, destinationPath, true);
        }
        finally
        {
            if (File.Exists(temp)) File.Delete(temp);
        }
        return new BackupSummary(settings.Count, hasBackground, appVersion);
    }

    public async Task<BackupSummary> ImportAsync(string archivePath, CancellationToken cancellationToken = default)
    {
        using var archive = ZipFile.OpenRead(archivePath);

        var manifestEntry = archive.GetEntry(ManifestName)
            ?? throw new InvalidDataException("Not a micaGO settings backup (missing manifest).");
        using var manifest = JsonDocument.Parse(await ReadEntryAsync(manifestEntry, cancellationToken));
        var format = manifest.RootElement.TryGetProperty("format", out var formatValue) ? formatValue.GetString() : null;
        if (!string.Equals(format, FormatId, StringComparison.Ordinal))
        {
            throw new InvalidDataException("This backup was not created by the Windows client.");
        }
        var appVersion = manifest.RootElement.TryGetProperty("appVersion", out var versionValue)
            ? versionValue.GetString() ?? "?" : "?";

        var settingsEntry = archive.GetEntry(SettingsName)
            ?? throw new InvalidDataException("The backup does not contain settings.");
        var settings = JsonSerializer.Deserialize<Dictionary<string, string>>(await ReadEntryAsync(settingsEntry, cancellationToken)) ?? [];

        // Restore the chat background asset first so the settings key can be
        // rewritten to this machine's path.
        var backgroundEntry = archive.Entries.FirstOrDefault(entry =>
            entry.FullName.StartsWith(BackgroundEntryPrefix, StringComparison.OrdinalIgnoreCase));
        var hasBackground = backgroundEntry is not null;
        if (backgroundEntry is not null)
        {
            var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "micaGO", "appearance");
            Directory.CreateDirectory(directory);
            var destination = Path.Combine(directory, "chat-background" + Path.GetExtension(backgroundEntry.FullName));
            backgroundEntry.ExtractToFile(destination, true);
            settings[BackgroundKey] = destination;
        }
        else
        {
            settings.Remove(BackgroundKey);
        }

        foreach (var key in ExcludedKeys) settings.Remove(key);
        foreach (var (key, value) in settings)
        {
            await cache.SetSettingAsync(key, value, cancellationToken);
        }
        if(archive.GetEntry(HiddenMessagesName) is{} hiddenMessages)
            await cache.HideMessagesAsync(JsonSerializer.Deserialize<string[]>(await ReadEntryAsync(hiddenMessages,cancellationToken))??[],cancellationToken);
        if(archive.GetEntry(HiddenChatsName) is{} hiddenChats)
            await cache.HideChatsAsync(JsonSerializer.Deserialize<string[]>(await ReadEntryAsync(hiddenChats,cancellationToken))??[],cancellationToken);
        return new BackupSummary(settings.Count, hasBackground, appVersion);
    }

    private static async Task WriteEntryAsync(ZipArchive archive, string name, string content, CancellationToken cancellationToken)
    {
        var entry = archive.CreateEntry(name);
        await using var stream = entry.Open();
        await using var writer = new StreamWriter(stream);
        await writer.WriteAsync(content.AsMemory(), cancellationToken);
    }

    private static async Task<string> ReadEntryAsync(ZipArchiveEntry entry, CancellationToken cancellationToken)
    {
        await using var stream = entry.Open();
        using var reader = new StreamReader(stream);
        return await reader.ReadToEndAsync(cancellationToken);
    }
}

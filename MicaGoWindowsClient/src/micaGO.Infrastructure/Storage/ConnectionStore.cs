using System.Text.Json;
using System.Text.Json.Serialization;
using MicaGo.Core.Connection;

namespace MicaGo.Infrastructure.Storage;

public sealed class ConnectionStore : IConnectionStore
{
    private const string TokenKey = "server-token";
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    private readonly ISecretStore _secrets;
    private readonly string _profilePath;

    public ConnectionStore(ISecretStore secrets, string? appDataRoot = null)
    {
        _secrets = secrets;
        var root = appDataRoot ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "micaGO");
        _profilePath = Path.Combine(root, "connection-profile.json");
    }

    public async Task<SavedConnection?> LoadAsync(CancellationToken cancellationToken = default)
    {
        if (!File.Exists(_profilePath))
        {
            return null;
        }

        var token = _secrets.Read(TokenKey);
        if (string.IsNullOrWhiteSpace(token))
        {
            return null;
        }

        await using var stream = File.OpenRead(_profilePath);
        var profile = await JsonSerializer.DeserializeAsync<ConnectionProfile>(stream, JsonOptions, cancellationToken);
        return profile is null ? null : new SavedConnection(profile, token);
    }

    public async Task SaveAsync(ConnectionProfile profile, string token, CancellationToken cancellationToken = default)
    {
        var directory = Path.GetDirectoryName(_profilePath)!;
        Directory.CreateDirectory(directory);
        _secrets.Write(TokenKey, token);

        var temporaryPath = _profilePath + ".tmp";
        try
        {
            await using (var stream = File.Create(temporaryPath))
            {
                await JsonSerializer.SerializeAsync(stream, profile, JsonOptions, cancellationToken);
                await stream.FlushAsync(cancellationToken);
            }

            File.Move(temporaryPath, _profilePath, true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    public Task ClearAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        _secrets.Delete(TokenKey);
        if (File.Exists(_profilePath))
        {
            File.Delete(_profilePath);
        }

        return Task.CompletedTask;
    }
}

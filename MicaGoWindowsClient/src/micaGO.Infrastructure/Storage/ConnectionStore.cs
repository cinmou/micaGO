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

    private readonly SemaphoreSlim _stateGate=new(1,1);
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

    public async Task PrepareAsync(CancellationToken cancellationToken = default)
    {
        await _stateGate.WaitAsync(cancellationToken);
        var key = "credential-probe-" + Guid.NewGuid().ToString("N");
        try
        {
            var value = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(32));
            _secrets.Write(key, value);
            if (_secrets.Read(key) != value) throw new System.ComponentModel.Win32Exception("Credential Manager verification failed.");
        }
        finally { try { _secrets.Delete(key); } finally { _stateGate.Release(); } }
    }

    public async Task<SavedConnection?> LoadAsync(CancellationToken cancellationToken = default)
    {
        await _stateGate.WaitAsync(cancellationToken);
        try
        {
            if (!File.Exists(_profilePath)) return null;
            var token = _secrets.Read(TokenKey);
            if (string.IsNullOrWhiteSpace(token)) return null;
            await using var stream = File.OpenRead(_profilePath);
            var profile = await JsonSerializer.DeserializeAsync<ConnectionProfile>(stream, JsonOptions, cancellationToken);
            return profile is null ? null : new SavedConnection(profile, token);
        }
        finally { _stateGate.Release(); }
    }

    public async Task SaveAsync(ConnectionProfile profile, string token, CancellationToken cancellationToken = default)
    {
        await _stateGate.WaitAsync(cancellationToken);
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_profilePath)!);
            var temporaryPath = _profilePath + ".tmp";
            try
            {
                await using (var stream = File.Create(temporaryPath))
                {
                    await JsonSerializer.SerializeAsync(stream, profile, JsonOptions, cancellationToken);
                    await stream.FlushAsync(cancellationToken);
                }
                cancellationToken.ThrowIfCancellationRequested();
                var priorToken = _secrets.Read(TokenKey);
                _secrets.Write(TokenKey, token);
                try { File.Move(temporaryPath, _profilePath, true); }
                catch
                {
                    if (priorToken is null) _secrets.Delete(TokenKey);
                    else _secrets.Write(TokenKey, priorToken);
                    throw;
                }
            }
            finally
            {
                if (File.Exists(temporaryPath)) File.Delete(temporaryPath);
            }
        }
        finally { _stateGate.Release(); }
    }

    public async Task ClearAsync(CancellationToken cancellationToken = default)
    {
        await _stateGate.WaitAsync(cancellationToken);
        try
        {
            if (File.Exists(_profilePath)) File.Delete(_profilePath);
            _secrets.Delete(TokenKey);
        }
        finally { _stateGate.Release(); }
    }
}

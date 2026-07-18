using MicaGo.Core.Connection;

namespace MicaGo.Infrastructure.Storage;

public interface IConnectionStore
{
    Task<SavedConnection?> LoadAsync(CancellationToken cancellationToken = default);
    Task SaveAsync(ConnectionProfile profile, string token, CancellationToken cancellationToken = default);
    Task ClearAsync(CancellationToken cancellationToken = default);
}

public interface ISecretStore
{
    string? Read(string key);
    void Write(string key, string value);
    void Delete(string key);
}

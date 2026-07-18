using MicaGo.Infrastructure.Connection;
using MicaGo.Infrastructure.Storage;

namespace MicaGo.App.Services;

public sealed class AppServices : IDisposable
{
    public static AppServices Current { get; } = new();

    private AppServices()
    {
        var secrets = new CredentialManagerSecretStore();
        Connection = new ConnectionManager(
            new ConnectionStore(secrets),
            new EndpointSelector());
    }

    public ConnectionManager Connection { get; }

    public void Dispose()
    {
        Connection.Dispose();
    }
}

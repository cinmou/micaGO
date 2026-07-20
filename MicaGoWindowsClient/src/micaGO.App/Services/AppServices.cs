using MicaGo.Infrastructure.Connection;
using MicaGo.Infrastructure.Storage;
using MicaGo.Infrastructure.Contacts;

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
        Cache = new LocalCacheStore();
        Media = new MediaCache();
        Localization = new LocalizationService();
        Notifications = new NotificationService();
        Appearance = new AppearanceService(Cache);
        secrets.Delete("google-contacts-refresh-token");
        VcfContacts = new VcfContactImporter(Cache);
    }

    public ConnectionManager Connection { get; }
    public LocalCacheStore Cache { get; }
    public MediaCache Media { get; }
    public LocalizationService Localization { get; }
    public NotificationService Notifications { get; }
    public AppearanceService Appearance { get; }
    public VcfContactImporter VcfContacts { get; }

    public async Task RemoveLegacyGoogleContactsAsync(CancellationToken cancellationToken = default)
    {
        await Cache.InitializeAsync();
        await Cache.ClearContactsBySourceAsync("google", cancellationToken);
        foreach (var key in new[] { "google.clientId", "google.syncToken", "google.lastSync" })
            await Cache.SetSettingAsync(key, string.Empty, cancellationToken);
    }

    public void Dispose()
    {
        Connection.Dispose();
        Cache.Dispose();
        Notifications.Dispose();
    }
}

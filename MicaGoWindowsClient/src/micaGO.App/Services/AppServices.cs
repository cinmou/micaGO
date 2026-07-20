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
        GoogleContacts = new GoogleContactsService(Cache, secrets);
        VcfContacts = new VcfContactImporter(Cache);
    }

    public ConnectionManager Connection { get; }
    public LocalCacheStore Cache { get; }
    public MediaCache Media { get; }
    public LocalizationService Localization { get; }
    public NotificationService Notifications { get; }
    public AppearanceService Appearance { get; }
    public GoogleContactsService GoogleContacts { get; }
    public VcfContactImporter VcfContacts { get; }

    public void Dispose()
    {
        Connection.Dispose();
        Cache.Dispose();
        Notifications.Dispose();
    }
}

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
        ChatPreferences = new ChatPreferenceSync(Cache, () => Connection.Api);
        MessagePreferences = new MessagePreferenceSync(Cache, () => Connection.Api);
        ReadState = new ReadStateSync(Cache, () => Connection.Api);
        DevicePresence = new DevicePresenceService(Connection, Cache);
        Media = new MediaCache();
        Connection.ConnectionChanged += (_, _) => Media.AccessAllowed = Connection.IsConnected && !Connection.TokenRejected;
        Localization = new LocalizationService();
        Notifications = new NotificationService();
        Appearance = new AppearanceService(Cache);
        secrets.Delete("google-contacts-refresh-token");
        VcfContacts = new VcfContactImporter(Cache);
        Backup = new SettingsBackupService(Cache);
    }

    public ConnectionManager Connection { get; }
    public LocalCacheStore Cache { get; }
    public ChatPreferenceSync ChatPreferences { get; }
    public MessagePreferenceSync MessagePreferences { get; }
    public ReadStateSync ReadState { get; }
    public DevicePresenceService DevicePresence { get; }
    public MediaCache Media { get; }
    public LocalizationService Localization { get; }
    public NotificationService Notifications { get; }
    public AppearanceService Appearance { get; }
    public VcfContactImporter VcfContacts { get; }
    public SettingsBackupService Backup { get; }

    private readonly SemaphoreSlim _rejectedCacheGate = new(1, 1);
    public async Task ClearRejectedContentAsync(bool rejected = false)
    {
        await _rejectedCacheGate.WaitAsync();
        try
        {
            if (rejected) await Cache.SetSettingAsync("auth.rejected", "true");
            if (await Cache.GetSettingAsync("auth.rejected") != "true") return;
            await Cache.ClearContentCacheAsync();
            await Media.ClearAsync();
            await Cache.SetSettingAsync("auth.rejected", "false");
        }
        finally { _rejectedCacheGate.Release(); }
    }

    public async Task RemoveLegacyGoogleContactsAsync(CancellationToken cancellationToken = default)
    {
        await Cache.InitializeAsync();
        await Cache.ClearContactsBySourceAsync("google", cancellationToken);
        foreach (var key in new[] { "google.clientId", "google.syncToken", "google.lastSync" })
            await Cache.SetSettingAsync(key, string.Empty, cancellationToken);
    }

    public void Dispose()
    {
        DevicePresence.Dispose();
        Connection.Dispose();
        Cache.Dispose();
        Notifications.Dispose();
    }
}

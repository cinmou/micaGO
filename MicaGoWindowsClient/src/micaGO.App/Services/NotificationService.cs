using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace MicaGo.App.Services;

public sealed class NotificationService : IDisposable
{
    private bool _registered;
    private AppNotificationManager? _manager;

    public bool Enabled { get; set; }
    public bool ShowMessageText { get; set; } = true;
    public string HiddenBodyText { get; set; } = "New message";
    public bool IsRegistered => _registered;
    public AppNotificationSetting? SystemSetting { get; private set; }
    public string? RegistrationError { get; private set; }

    /// <summary>Raised (on a background thread) when the user clicks a message notification.</summary>
    public event EventHandler<string>? ChatActivated;

    public bool Register()
    {
        if (_registered) return true;
        try
        {
            if (!AppNotificationManager.IsSupported())
            {
                RegistrationError = "Windows app notifications are not supported on this system.";
                SystemSetting = AppNotificationSetting.Unsupported;
                return false;
            }

            _manager = AppNotificationManager.Default;
            _manager.NotificationInvoked += OnNotificationInvoked;
            var iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "micaGO.Windows.png");
            if (File.Exists(iconPath)) _manager.Register("micaGO", new Uri(iconPath));
            else _manager.Register();
            SystemSetting = _manager.Setting;
            RegistrationError = null;
            _registered = true;
            return true;
        }
        catch (Exception exception)
        {
            if (_manager is not null) _manager.NotificationInvoked -= OnNotificationInvoked;
            _manager = null;
            _registered = false;
            SystemSetting = null;
            RegistrationError = $"0x{exception.HResult:X8}: {exception.Message}";
            System.Diagnostics.Debug.WriteLine($"[Notifications] registration failed: {RegistrationError}");
            return false;
        }
    }

    private void OnNotificationInvoked(AppNotificationManager sender, AppNotificationActivatedEventArgs args)
    {
        if (args.Arguments.TryGetValue("chat", out var chatId) && !string.IsNullOrWhiteSpace(chatId))
        {
            ChatActivated?.Invoke(this, chatId);
        }
    }

    public void Show(string title, string body, string chatId)
    {
        if (!Enabled) return;
        if (!Register() || _manager is null) return;
        try
        {
            var visibleBody = ShowMessageText ? body : HiddenBodyText;
            var notification = new AppNotificationBuilder().AddText(title).AddText(visibleBody).AddArgument("chat", chatId).BuildNotification();
            _manager.Show(notification);
        }
        catch (Exception exception)
        {
            System.Diagnostics.Debug.WriteLine($"[Notifications] show failed: 0x{exception.HResult:X8}: {exception.Message}");
        }
    }

    public void Dispose()
    {
        if (!_registered) return;
        try { _manager?.Unregister(); } catch { }
        if (_manager is not null) _manager.NotificationInvoked -= OnNotificationInvoked;
        _manager = null;
        _registered = false;
    }
}

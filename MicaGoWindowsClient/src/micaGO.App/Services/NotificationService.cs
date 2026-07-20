using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace MicaGo.App.Services;

public sealed class NotificationService : IDisposable
{
    private bool _registered;

    public bool Enabled { get; set; }

    /// <summary>Raised (on a background thread) when the user clicks a message notification.</summary>
    public event EventHandler<string>? ChatActivated;

    public void Register()
    {
        if (_registered) return;
        try
        {
            AppNotificationManager.Default.NotificationInvoked += OnNotificationInvoked;
            AppNotificationManager.Default.Register();
            _registered = true;
        }
        catch { _registered = false; }
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
        Register();
        if (!_registered) return;
        var notification = new AppNotificationBuilder().AddText(title).AddText(body).AddArgument("chat", chatId).BuildNotification();
        AppNotificationManager.Default.Show(notification);
    }

    public void Dispose()
    {
        if (!_registered) return;
        try { AppNotificationManager.Default.Unregister(); } catch { }
        _registered = false;
    }
}

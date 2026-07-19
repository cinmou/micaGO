using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace MicaGo.App.Services;

public sealed class NotificationService : IDisposable
{
    private bool _registered;
    public bool Enabled { get; set; }
    public void Register()
    {
        if (_registered) return;
        try { AppNotificationManager.Default.Register(); _registered = true; }
        catch { _registered = false; }
    }
    public void Show(string title, string body, string chatId)
    {
        if (!Enabled) return; Register(); if (!_registered) return;
        var notification = new AppNotificationBuilder().AddText(title).AddText(body).AddArgument("chat", chatId).BuildNotification();
        AppNotificationManager.Default.Show(notification);
    }
    public void Dispose() { if (_registered) { try { AppNotificationManager.Default.Unregister(); } catch { } _registered = false; } }
}


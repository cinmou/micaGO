using Microsoft.UI.Xaml;
using MicaGo.Core.Models;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace MicaGo.App;

/// <summary>Small pure helpers for x:Bind function bindings in item templates.</summary>
public static class Ui
{
    public static ImageSource? Image(string? path) =>
        string.IsNullOrWhiteSpace(path) || !File.Exists(path) ? null : new BitmapImage(new Uri(path));

    public static Visibility CountVisibility(bool hasUnread, int count, bool muted) =>
        ChatUnreadSemantics.Badge(hasUnread, count, muted) == UnreadBadgeKind.Count ? Visibility.Visible : Visibility.Collapsed;

    public static Visibility BoolVisibility(bool value) =>
        value ? Visibility.Visible : Visibility.Collapsed;

    public static Visibility PinVisibility(bool pinned, bool hasUnread) =>
        pinned && !hasUnread ? Visibility.Visible : Visibility.Collapsed;

    public static string CountLabel(int count) => count > 9999 ? "9999+" : count.ToString();

    /// <summary>Flutter parity: muted conversations or uncounted unread use a dot.</summary>
    public static Visibility DotVisibility(bool hasUnread, int unreadCount, bool muted) =>
        ChatUnreadSemantics.Badge(hasUnread, unreadCount, muted) == UnreadBadgeKind.Dot ? Visibility.Visible : Visibility.Collapsed;
}

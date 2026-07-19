using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace MicaGo.App;

/// <summary>Small pure helpers for x:Bind function bindings in item templates.</summary>
public static class Ui
{
    public static ImageSource? Image(string? path) =>
        string.IsNullOrWhiteSpace(path) || !File.Exists(path) ? null : new BitmapImage(new Uri(path));

    public static Visibility CountVisibility(int count) =>
        count > 0 ? Visibility.Visible : Visibility.Collapsed;

    public static Visibility BoolVisibility(bool value) =>
        value ? Visibility.Visible : Visibility.Collapsed;

    public static Visibility PinVisibility(bool pinned, int unread) =>
        pinned && unread == 0 ? Visibility.Visible : Visibility.Collapsed;

    public static string CountLabel(int count) => count > 99 ? "99+" : count.ToString();
}

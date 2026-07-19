using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using MicaGo.App.Services;
using Windows.Graphics;
using Windows.UI;

namespace MicaGo.App;

/// <summary>
/// The pairing window: a small fixed-size Mica window that hosts the
/// connection card. It is the first window shown at launch (the page inside
/// silently tries the saved connection) and reappears after a disconnect.
/// </summary>
public sealed partial class ConnectionWindow : Window
{
    private const double WindowWidth = 640;
    private const double WindowHeight = 560;

    public ConnectionWindow()
    {
        InitializeComponent();
        if (AppWindowTitleBar.IsCustomizationSupported())
        {
            ExtendsContentIntoTitleBar = true;
            SetTitleBar(AppTitleBar);
            AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Standard;
        }
        else
        {
            TitleBarRow.Height = new GridLength(0);
        }

        SystemBackdrop = new MicaBackdrop { Kind = MicaKind.Base };
        WindowRoot.Loaded += WindowRoot_Loaded;
        WindowRoot.ActualThemeChanged += (_, _) => ApplyTitleBarColors();

        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
        }
    }

    private async void WindowRoot_Loaded(object sender, RoutedEventArgs e)
    {
        ApplyTitleBarColors();
        ApplyDpiAwareWindowSize();
        await AppServices.Current.Cache.InitializeAsync();
        var theme = await AppServices.Current.Cache.GetSettingAsync("settings.theme");
        WindowRoot.RequestedTheme = theme switch
        {
            "light" => ElementTheme.Light,
            "dark" => ElementTheme.Dark,
            _ => ElementTheme.Default,
        };
    }

    private void ApplyTitleBarColors()
    {
        if (!AppWindowTitleBar.IsCustomizationSupported())
        {
            return;
        }

        var dark = WindowRoot.ActualTheme == ElementTheme.Dark;
        var foreground = dark
            ? Color.FromArgb(0xFF, 0xFF, 0xFF, 0xFF)
            : Color.FromArgb(0xFF, 0x00, 0x00, 0x00);
        AppWindow.TitleBar.ButtonForegroundColor = foreground;
        AppWindow.TitleBar.ButtonInactiveForegroundColor = Color.FromArgb(0x88, foreground.R, foreground.G, foreground.B);
        var transparent = Color.FromArgb(0, 0, 0, 0);
        AppWindow.TitleBar.ButtonBackgroundColor = transparent;
        AppWindow.TitleBar.ButtonInactiveBackgroundColor = transparent;
        AppWindow.TitleBar.ButtonHoverBackgroundColor = dark
            ? Color.FromArgb(0x19, 0xFF, 0xFF, 0xFF)
            : Color.FromArgb(0x19, 0x00, 0x00, 0x00);
        AppWindow.TitleBar.ButtonPressedBackgroundColor = dark
            ? Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF)
            : Color.FromArgb(0x33, 0x00, 0x00, 0x00);
    }

    private void ApplyDpiAwareWindowSize()
    {
        var scale = WindowRoot.XamlRoot?.RasterizationScale ?? 1;
        var workArea = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var width = Math.Min((int)Math.Round(WindowWidth * scale), workArea.Width);
        var height = Math.Min((int)Math.Round(WindowHeight * scale), workArea.Height);
        var x = workArea.X + Math.Max(0, (workArea.Width - width) / 2);
        var y = workArea.Y + Math.Max(0, (workArea.Height - height) / 2);
        AppWindow.MoveAndResize(new RectInt32(x, y, width, height));
    }
}

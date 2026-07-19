using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using MicaGo.App.Services;
using MicaGo.App.Views;
using Windows.Graphics;
using Windows.UI;

namespace MicaGo.App;

public sealed partial class MainWindow : Window
{
    private const double InitialWidth = 1180;
    private const double InitialHeight = 760;
    private const double MinimumWidth = 880;
    private const double MinimumHeight = 600;

    public MainWindow()
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

        Closed += (_, _) => AppServices.Current.Dispose();
        RootFrame.Navigate(typeof(ConnectionPage));
    }

    private void WindowRoot_Loaded(object sender, RoutedEventArgs e)
    {
        WindowRoot.Loaded -= WindowRoot_Loaded;
        ApplyTitleBarColors();
        ApplyDpiAwareWindowSize();
        _ = LoadPlatformSettingsAsync();
        if (WindowRoot.XamlRoot is not null)
        {
            WindowRoot.XamlRoot.Changed += (_, _) => UpdateMinimumSize(WindowRoot.XamlRoot.RasterizationScale);
        }
    }

    private async Task LoadPlatformSettingsAsync()
    {
        await AppServices.Current.Cache.InitializeAsync();
        AppServices.Current.Notifications.Enabled = await AppServices.Current.Cache.GetSettingAsync("settings.notifications") != "false";
        var language = await AppServices.Current.Cache.GetSettingAsync("settings.language");
        if (!string.IsNullOrWhiteSpace(language)) AppServices.Current.Localization.SetLanguage(language);
        var theme = await AppServices.Current.Cache.GetSettingAsync("settings.theme");
        WindowRoot.RequestedTheme = theme switch { "light" => ElementTheme.Light, "dark" => ElementTheme.Dark, _ => ElementTheme.Default };
    }

    private void TitleBarSettingsButton_Click(object sender, RoutedEventArgs e)
    {
        if (RootFrame.Content is ShellPage shell) shell.OpenSettings();
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
        var width = Math.Min((int)Math.Round(InitialWidth * scale), workArea.Width);
        var height = Math.Min((int)Math.Round(InitialHeight * scale), workArea.Height);
        var x = workArea.X + Math.Max(0, (workArea.Width - width) / 2);
        var y = workArea.Y + Math.Max(0, (workArea.Height - height) / 2);
        AppWindow.MoveAndResize(new RectInt32(x, y, width, height));
        UpdateMinimumSize(scale);
    }

    private void UpdateMinimumSize(double scale)
    {
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            var workArea = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
            presenter.PreferredMinimumWidth = Math.Min((int)Math.Round(MinimumWidth * scale), workArea.Width);
            presenter.PreferredMinimumHeight = Math.Min((int)Math.Round(MinimumHeight * scale), workArea.Height);
        }
    }
}

using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using MicaGo.App.Services;
using MicaGo.App.Views;
using Windows.Graphics;
using Windows.UI;

namespace MicaGo.App;

public sealed class ConnectionWindow : Window
{
    private const double WindowWidth = 640;
    private const double WindowHeight = 560;
    private readonly Grid _windowRoot = new() { Background = null };
    private readonly RowDefinition _titleBarRow = new() { Height = new GridLength(40) };
    private readonly Grid _appTitleBar = new() { Background = null };

    public ConnectionWindow()
    {
        Title = "micaGO";
        var iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "micaGO.ico");
        if (File.Exists(iconPath)) AppWindow.SetIcon(iconPath);
        Content = BuildContent();
        if (AppWindowTitleBar.IsCustomizationSupported())
        {
            ExtendsContentIntoTitleBar = true;
            SetTitleBar(_appTitleBar);
            AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Standard;
        }
        else _titleBarRow.Height = new GridLength(0);

        SystemBackdrop = new MicaBackdrop { Kind = MicaKind.Base };
        _windowRoot.Loaded += WindowRoot_Loaded;
        _windowRoot.ActualThemeChanged += (_, _) => ApplyTitleBarColors();
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
        }
    }

    private UIElement BuildContent()
    {
        _windowRoot.RowDefinitions.Add(_titleBarRow);
        _windowRoot.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _windowRoot.Children.Add(_appTitleBar);
        var page = new ConnectionPage();
        Grid.SetRow(page, 1);
        _windowRoot.Children.Add(page);
        return _windowRoot;
    }

    private async void WindowRoot_Loaded(object sender, RoutedEventArgs e)
    {
        _windowRoot.Loaded -= WindowRoot_Loaded;
        ApplyTitleBarColors();
        ApplyDpiAwareWindowSize();
        await AppServices.Current.Cache.InitializeAsync();
        var theme = await AppServices.Current.Cache.GetSettingAsync("settings.theme");
        _windowRoot.RequestedTheme = theme switch { "light" => ElementTheme.Light, "dark" => ElementTheme.Dark, _ => ElementTheme.Default };
    }

    private void ApplyTitleBarColors()
    {
        if (!AppWindowTitleBar.IsCustomizationSupported()) return;
        var dark = _windowRoot.ActualTheme == ElementTheme.Dark;
        var foreground = dark ? Color.FromArgb(0xFF, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0xFF, 0, 0, 0);
        AppWindow.TitleBar.ButtonForegroundColor = foreground;
        AppWindow.TitleBar.ButtonInactiveForegroundColor = Color.FromArgb(0x88, foreground.R, foreground.G, foreground.B);
        var transparent = Color.FromArgb(0, 0, 0, 0);
        AppWindow.TitleBar.ButtonBackgroundColor = transparent;
        AppWindow.TitleBar.ButtonInactiveBackgroundColor = transparent;
        AppWindow.TitleBar.ButtonHoverBackgroundColor = dark ? Color.FromArgb(0x19, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0x19, 0, 0, 0);
        AppWindow.TitleBar.ButtonPressedBackgroundColor = dark ? Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0x33, 0, 0, 0);
    }

    private void ApplyDpiAwareWindowSize()
    {
        var scale = _windowRoot.XamlRoot?.RasterizationScale ?? 1;
        var workArea = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var width = Math.Min((int)Math.Round(WindowWidth * scale), workArea.Width);
        var height = Math.Min((int)Math.Round(WindowHeight * scale), workArea.Height);
        AppWindow.MoveAndResize(new RectInt32(
            workArea.X + Math.Max(0, (workArea.Width - width) / 2),
            workArea.Y + Math.Max(0, (workArea.Height - height) / 2), width, height));
    }
}

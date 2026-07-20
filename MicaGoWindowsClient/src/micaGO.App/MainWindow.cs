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

public sealed class MainWindow : Window
{
    private const double InitialWidth = 1180;
    private const double InitialHeight = 760;
    private const double MinimumWidth = 880;
    private const double MinimumHeight = 600;
    private readonly Grid _windowRoot = new() { Background = null };
    private readonly RowDefinition _titleBarRow = new() { Height = new GridLength(48) };
    private readonly Grid _appTitleBar = new() { Background = null };
    private readonly ShellPage _shellPage;

    public MainWindow()
    {
        Title = "micaGO";
        _shellPage = new ShellPage();
        Content = BuildContent();
        AppWindow.Closing += AppWindow_Closing;
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
        Closed += async (_, _) => await _shellPage.ShutdownAsync();
    }

    private UIElement BuildContent()
    {
        _windowRoot.RowDefinitions.Add(_titleBarRow);
        _windowRoot.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _appTitleBar.Children.Add(new TextBlock
        {
            Text = "micaGO",
            Margin = new Thickness(16, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center,
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            IsHitTestVisible = false,
        });
        _windowRoot.Children.Add(_appTitleBar);
        Grid.SetRow(_shellPage, 1);
        _windowRoot.Children.Add(_shellPage);
        return _windowRoot;
    }

    private void AppWindow_Closing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (!App.ShouldHideWindowOnClose) return;
        args.Cancel = true;
        App.HideWindow(this);
    }

    public Task OpenChatAsync(string chatId) => _shellPage.OpenChatAsync(chatId);

    private void WindowRoot_Loaded(object sender, RoutedEventArgs e)
    {
        _windowRoot.Loaded -= WindowRoot_Loaded;
        ApplyTitleBarColors();
        ApplyDpiAwareWindowSize();
        _ = LoadPlatformSettingsAsync();
        if (_windowRoot.XamlRoot is not null)
            _windowRoot.XamlRoot.Changed += (_, _) => UpdateMinimumSize(_windowRoot.XamlRoot.RasterizationScale);
    }

    private async Task LoadPlatformSettingsAsync()
    {
        await AppServices.Current.Cache.InitializeAsync();
        AppServices.Current.Notifications.Enabled = await AppServices.Current.Cache.GetSettingAsync("settings.notifications") != "false";
        var language = await AppServices.Current.Cache.GetSettingAsync("settings.language");
        if (!string.IsNullOrWhiteSpace(language)) AppServices.Current.Localization.SetLanguage(language);
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
        var width = Math.Min((int)Math.Round(InitialWidth * scale), workArea.Width);
        var height = Math.Min((int)Math.Round(InitialHeight * scale), workArea.Height);
        AppWindow.MoveAndResize(new RectInt32(
            workArea.X + Math.Max(0, (workArea.Width - width) / 2),
            workArea.Y + Math.Max(0, (workArea.Height - height) / 2), width, height));
        UpdateMinimumSize(scale);
    }

    private void UpdateMinimumSize(double scale)
    {
        if (AppWindow.Presenter is not OverlappedPresenter presenter) return;
        var workArea = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        presenter.PreferredMinimumWidth = Math.Min((int)Math.Round(MinimumWidth * scale), workArea.Width);
        presenter.PreferredMinimumHeight = Math.Min((int)Math.Round(MinimumHeight * scale), workArea.Height);
    }
}

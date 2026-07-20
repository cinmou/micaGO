using Microsoft.UI.Xaml;
using MicaGo.App.Services;
using System.Runtime.InteropServices;

namespace MicaGo.App;

public partial class App : Application
{
    /// <summary>The chat window. Null while the pairing window is the only window.</summary>
    public static Window MainWindow { get; private set; } = null!;

    private static ConnectionWindow? _connectionWindow;
    private static bool _switchingWindows;
    private static bool _isExiting;
    private static bool _servicesDisposed;
    private static TrayIconService? _tray;

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, args) => WriteStartupFailure(args.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, args) => WriteStartupFailure(args.ExceptionObject as Exception);
    }

    private static void WriteStartupFailure(Exception? exception)
    {
        try
        {
            var directory=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"micaGO");
            Directory.CreateDirectory(directory);
            File.AppendAllText(Path.Combine(directory,"startup-crash.log"),$"{DateTimeOffset.Now:O}\r\n{exception}\r\n\r\n");
        }
        catch { }
    }

    internal static void ReportStartupFailure(Exception exception) => WriteStartupFailure(exception);

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // The pairing window doubles as the launch splash: it silently tries
        // the saved connection first and promotes itself to the chat window.
        ShowConnectionWindow();
        _ = RestoreTrayAsync();
    }

    public static bool ShouldHideWindowOnClose => !_switchingWindows && !_isExiting && _tray is not null;

    private static async Task RestoreTrayAsync()
    {
        await AppServices.Current.Cache.InitializeAsync();
        if (await AppServices.Current.Cache.GetSettingAsync("settings.tray") == "true") await SetTrayEnabledAsync(true);
    }

    public static async Task SetTrayEnabledAsync(bool enabled)
    {
        await AppServices.Current.Cache.InitializeAsync();
        await AppServices.Current.Cache.SetSettingAsync("settings.tray", enabled ? "true" : "false");
        if (enabled && _tray is null)
        {
            _tray = new TrayIconService(Path.Combine(AppContext.BaseDirectory, "Assets", "micaGO.ico"));
            _tray.OpenRequested += (_, _) => ShowCurrentWindow();
            _tray.ExitRequested += (_, _) => ExitFromTray();
            _tray.ContactRequested += async (_, contact) => { ShowCurrentWindow(); if (MainWindow is MainWindow main) await main.OpenChatAsync(contact.Id); };
        }
        else if (!enabled && _tray is not null) { _tray.Dispose(); _tray = null; }
    }

    public static void UpdateTrayContacts(IEnumerable<TrayContact> contacts) => _tray?.UpdateRecentContacts(contacts);

    public static void HideWindow(Window window) => ShowWindow(WinRT.Interop.WindowNative.GetWindowHandle(window), 0);

    private static void ShowCurrentWindow()
    {
        var window = MainWindow ?? (Window?)_connectionWindow;
        if (window is null) { ShowConnectionWindow(); return; }
        ShowWindow(WinRT.Interop.WindowNative.GetWindowHandle(window), 9);
        window.Activate();
    }

    private static void ExitFromTray()
    {
        _isExiting = true;
        _tray?.Dispose(); _tray = null;
        MainWindow?.Close();
        _connectionWindow?.Close();
        DisposeServices();
        Current.Exit();
    }

    /// <summary>Opens the chat window and closes the pairing window, if any.</summary>
    public static void ShowMainWindow()
    {
        _switchingWindows = true;
        try
        {
            var window = new MainWindow();
            window.Closed += OnHostWindowClosed;
            MainWindow = window;
            window.Activate();
            var pairing = _connectionWindow;
            _connectionWindow = null;
            pairing?.Close();
        }
        finally
        {
            _switchingWindows = false;
        }
    }

    /// <summary>Opens the pairing window and closes the chat window, if any.</summary>
    public static void ShowConnectionWindow()
    {
        _switchingWindows = true;
        try
        {
            var window = new ConnectionWindow();
            window.Closed += OnHostWindowClosed;
            _connectionWindow = window;
            window.Activate();
            var main = MainWindow;
            MainWindow = null!;
            main?.Close();
        }
        finally
        {
            _switchingWindows = false;
        }
    }

    private static void OnHostWindowClosed(object sender, WindowEventArgs args)
    {
        // Only dispose when the user really closed the last window — not when
        // we are swapping between the pairing window and the chat window.
        if (_switchingWindows)
        {
            return;
        }
        DisposeServices();
    }

    private static void DisposeServices(){if(_servicesDisposed)return;_servicesDisposed=true;AppServices.Current.Dispose();}

    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr window, int command);
}

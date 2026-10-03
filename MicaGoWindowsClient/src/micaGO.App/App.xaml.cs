using Microsoft.UI.Xaml;
using MicaGo.App.Services;
using System.Runtime.InteropServices;

namespace MicaGo.App;

public partial class App : Application
{
    /// <summary>The chat window. Null while the pairing window is the only window.</summary>
    public static Window MainWindow { get; private set; } = null!;

    private static Microsoft.UI.Dispatching.DispatcherQueue? _dispatcher;
    private static ConnectionWindow? _connectionWindow;
    internal static Window ConnectionHost => _connectionWindow ?? throw new InvalidOperationException("Pairing window is not open.");
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
        _dispatcher = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        _ = LaunchAsync();
    }

    private static async Task LaunchAsync()
    {
        try
        {
            await AppServices.Current.Cache.InitializeAsync();
            await AppServices.Current.ClearRejectedContentAsync();
            await LoadNotificationPreferencesAsync();
            AppServices.Current.Connection.CredentialRejected += OnCredentialRejected;
            AppServices.Current.Notifications.ChatActivated += OnNotificationChatActivated;
            AppServices.Current.Notifications.ReplyRequested += OnNotificationReplyRequested;
            AppServices.Current.Notifications.Register();
            if (await AppServices.Current.Cache.GetSettingAsync("settings.tray") == "true") await SetTrayEnabledAsync(true);
            // An already-paired PC goes straight to the chat window (which
            // finishes the reconnect in the background) — the pairing window
            // only appears when nothing is saved or the restore fails.
            var paired = false;
            try { paired = await AppServices.Current.Connection.HasSavedProfileAsync(); }
            catch { }
            if (paired) ShowMainWindow();
            else ShowConnectionWindow();
        }
        catch (Exception exception)
        {
            WriteStartupFailure(exception);
            ShowConnectionWindow();
        }
    }

    private static void OnCredentialRejected(object? sender, EventArgs args)
    {
        var window = MainWindow ?? (Window?)_connectionWindow;
        window?.DispatcherQueue.TryEnqueue(async () =>
        {
            if (!AppServices.Current.Connection.TokenRejected) return;
            // Remove history and any open media/settings surface before showing pairing.
            if (MainWindow?.Content is FrameworkElement content) content.Visibility = Visibility.Collapsed;
            AppServices.Current.Notifications.Enabled = false;
            UpdateTrayContacts([]);
            try
            {
                if (MainWindow is MainWindow main) await main.StopRejectedSessionAsync();
                MicaGo.App.Controls.MessageBubble.ClearPrivateMedia();
                await AppServices.Current.Notifications.DismissAllAsync();
                await AppServices.Current.ClearRejectedContentAsync(rejected: true);
            }
            catch (Exception error) { WriteStartupFailure(error); }
            if (_connectionWindow is null) ShowConnectionWindow();
        });
    }

    private static async Task LoadNotificationPreferencesAsync()
    {
        var services = AppServices.Current;
        var notificationsEnabled = await services.Cache.GetSettingAsync("settings.notifications") != "false";
        services.Notifications.Enabled = notificationsEnabled && !services.Connection.TokenRejected;
        services.Notifications.ShowMessageText = await services.Cache.GetSettingAsync("settings.notificationPreview") != "false";
        var language = await services.Cache.GetSettingAsync("settings.language");
        if (!string.IsNullOrWhiteSpace(language)) services.Localization.SetLanguage(language);
        services.Notifications.HiddenBodyText = services.Localization["newMessage"];
    }

    private static void OnNotificationReplyRequested(object? sender, (string ChatId, string DeviceId, string Text) reply)
    {
        _dispatcher?.TryEnqueue(async () =>
        {
            var services = AppServices.Current;
            var result = MicaGo.Infrastructure.Connection.NotificationReplyResult.Failed;
            try
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(35));
                if (!services.Connection.IsConnected) await services.Connection.TryRestoreAsync(timeout.Token);
                result = await new MicaGo.Infrastructure.Connection.NotificationReplySender(() => services.Connection.Api, () => services.Connection.Profile?.DeviceId)
                    .SendAsync(reply.ChatId, reply.DeviceId, reply.Text, timeout.Token);
            }
            catch { }
            if (result == MicaGo.Infrastructure.Connection.NotificationReplyResult.Sent) await services.Notifications.DismissChatAsync(reply.ChatId);
            else services.Notifications.ShowReplyStatus(reply.ChatId, services.Localization[result == MicaGo.Infrastructure.Connection.NotificationReplyResult.Pending ? "notificationReplyPending" : result == MicaGo.Infrastructure.Connection.NotificationReplyResult.Rejected ? "notificationReplyRejected" : "notificationReplyFailed"]);
        });
    }

    private static void OnNotificationChatActivated(object? sender, string chatId)
    {
        var window = MainWindow ?? (Window?)_connectionWindow;
        window?.DispatcherQueue.TryEnqueue(async () =>
        {
            ShowCurrentWindow();
            if (MainWindow is MainWindow main) await main.OpenChatAsync(chatId);
        });
    }

    public static bool ShouldHideWindowOnClose => !_switchingWindows && !_isExiting && _tray is not null;

    public static async Task SetTrayEnabledAsync(bool enabled)
    {
        await AppServices.Current.Cache.InitializeAsync();
        if (enabled && _tray is null)
        {
            try
            {
                var tray = new TrayIconService(Path.Combine(AppContext.BaseDirectory, "Assets", "micaGO.ico"));
                tray.OpenRequested += (_, _) => ShowCurrentWindow();
                tray.ExitRequested += (_, _) => ExitFromTray();
                tray.ContactRequested += async (_, contact) => { ShowCurrentWindow(); if (MainWindow is MainWindow main) await main.OpenChatAsync(contact.Id); };
                _tray = tray;
                await AppServices.Current.Cache.SetSettingAsync("settings.tray", "true");
            }
            catch (Exception exception)
            {
                _tray?.Dispose();
                _tray = null;
                WriteStartupFailure(exception);
                await AppServices.Current.Cache.SetSettingAsync("settings.tray", "false");
            }
        }
        else if (!enabled)
        {
            _tray?.Dispose();
            _tray = null;
            await AppServices.Current.Cache.SetSettingAsync("settings.tray", "false");
        }
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
            if (AppServices.Current.Connection.TokenRejected) return;
            _ = LoadNotificationPreferencesAsync();
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

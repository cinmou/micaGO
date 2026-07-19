using Microsoft.UI.Xaml;
using MicaGo.App.Services;

namespace MicaGo.App;

public partial class App : Application
{
    /// <summary>The chat window. Null while the pairing window is the only window.</summary>
    public static Window MainWindow { get; private set; } = null!;

    private static ConnectionWindow? _connectionWindow;
    private static bool _switchingWindows;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // The pairing window doubles as the launch splash: it silently tries
        // the saved connection first and promotes itself to the chat window.
        ShowConnectionWindow();
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
        AppServices.Current.Dispose();
    }
}

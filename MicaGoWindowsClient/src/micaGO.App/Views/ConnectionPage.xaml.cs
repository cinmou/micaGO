using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using MicaGo.App.Services;
using MicaGo.Core.Connection;
using MicaGo.Infrastructure.Connection;

namespace MicaGo.App.Views;

public sealed partial class ConnectionPage : Page
{
    private CancellationTokenSource? _connectionCancellation;
    private bool _restoreAttempted;

    public ConnectionPage()
    {
        InitializeComponent();
        Loaded += ConnectionPage_Loaded;
        Unloaded += ConnectionPage_Unloaded;
    }

    private async void ConnectionPage_Loaded(object sender, RoutedEventArgs e)
    {
        if (_restoreAttempted)
        {
            return;
        }
        _restoreAttempted = true;

        await AppServices.Current.Cache.InitializeAsync();
        var language = await AppServices.Current.Cache.GetSettingAsync("settings.language");
        if (!string.IsNullOrWhiteSpace(language))
        {
            AppServices.Current.Localization.SetLanguage(language);
        }
        ApplyText();

        await RestoreConnectionAsync();
    }

    private void ApplyText()
    {
        var l = AppServices.Current.Localization;
        SubtitleText.Text = l["connSubtitle"];
        PairingJsonLabel.Text = l["connPairingJson"];
        PairingJsonBox.PlaceholderText = l["connPlaceholder"];
        TokenNoteText.Text = l["connTokenNote"];
        ConnectButton.Content = l["connConnect"];
    }

    /// <summary>
    /// Silent auto-reconnect: the saved profile + Credential Manager token are
    /// probed first, so an already-paired PC goes straight to the chat window.
    /// </summary>
    private async Task RestoreConnectionAsync()
    {
        var l = AppServices.Current.Localization;
        SetBusy(true, l["connChecking"]);
        _connectionCancellation = new CancellationTokenSource(TimeSpan.FromSeconds(8));
        try
        {
            if (await AppServices.Current.Connection.TryRestoreAsync(_connectionCancellation.Token))
            {
                App.ShowMainWindow();
                return;
            }
            ShowStatus(l["connPaste"], InfoBarSeverity.Informational);
        }
        catch (OperationCanceledException)
        {
            ShowStatus(l["connTimeout"], InfoBarSeverity.Informational);
        }
        catch (Exception exception)
        {
            ShowStatus(string.Format(l["connRestoreFailed"], SafeMessage(exception)), InfoBarSeverity.Warning);
        }
        finally
        {
            SetBusy(false, string.Empty);
        }
    }

    private async void ConnectButton_Click(object sender, RoutedEventArgs e)
    {
        _connectionCancellation?.Cancel();
        _connectionCancellation = new CancellationTokenSource();
        SetBusy(true, AppServices.Current.Localization["connTesting"]);
        StatusBar.IsOpen = false;
        try
        {
            await AppServices.Current.Connection.ConnectPairingJsonAsync(
                PairingJsonBox.Password,
                _connectionCancellation.Token);
            PairingJsonBox.Password = string.Empty;
            App.ShowMainWindow();
        }
        catch (PairingPayloadException exception)
        {
            ShowStatus(exception.Message, InfoBarSeverity.Error);
        }
        catch (ConnectionException exception)
        {
            ShowStatus(exception.Message, InfoBarSeverity.Error);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            ShowStatus($"Connection failed: {SafeMessage(exception)}", InfoBarSeverity.Error);
        }
        finally
        {
            SetBusy(false, string.Empty);
        }
    }

    private void PairingJsonBox_PasswordChanged(object sender, RoutedEventArgs e)
    {
        ConnectButton.IsEnabled = !ConnectProgress.IsActive && !string.IsNullOrWhiteSpace(PairingJsonBox.Password);
    }

    private void SetBusy(bool busy, string phase)
    {
        ConnectProgress.IsActive = busy;
        PairingJsonBox.IsEnabled = !busy;
        ConnectButton.IsEnabled = !busy && !string.IsNullOrWhiteSpace(PairingJsonBox.Password);
        ConnectPhaseText.Text = phase;
    }

    private void ShowStatus(string message, InfoBarSeverity severity)
    {
        StatusBar.Message = message;
        StatusBar.Severity = severity;
        StatusBar.IsOpen = true;
    }

    private static string SafeMessage(Exception exception) => exception switch
    {
        System.ComponentModel.Win32Exception => "Windows Credential Manager is unavailable.",
        HttpRequestException => "The server could not be reached.",
        _ => exception.Message,
    };

    private void ConnectionPage_Unloaded(object sender, RoutedEventArgs e)
    {
        _connectionCancellation?.Cancel();
        _connectionCancellation?.Dispose();
        _connectionCancellation = null;
    }
}

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
        ShowStatus("Paste a pairing JSON to connect this PC.",InfoBarSeverity.Informational);
        await Task.CompletedTask;
    }

    private async Task RestoreConnectionAsync()
    {
        ShowStatus("Paste a pairing JSON, or wait while micaGO checks the saved connection.",InfoBarSeverity.Informational);
        _connectionCancellation = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        try
        {
            if (await AppServices.Current.Connection.TryRestoreAsync(_connectionCancellation.Token))
            {
                NavigateToChats();
                return;
            }

            ShowStatus("Paste a pairing JSON to connect this PC.", InfoBarSeverity.Informational);
        }
        catch (OperationCanceledException)
        {
            ShowStatus("Saved connection check timed out. Paste a pairing JSON to continue.",InfoBarSeverity.Informational);
        }
        catch (Exception exception)
        {
            ShowStatus($"The saved connection could not be restored: {SafeMessage(exception)}", InfoBarSeverity.Warning);
        }
    }

    private async void ConnectButton_Click(object sender, RoutedEventArgs e)
    {
        _connectionCancellation?.Cancel();
        _connectionCancellation = new CancellationTokenSource();
        SetBusy(true, "Testing LAN routes...");
        StatusBar.IsOpen = false;
        try
        {
            await AppServices.Current.Connection.ConnectPairingJsonAsync(
                PairingJsonBox.Password,
                _connectionCancellation.Token);
            PairingJsonBox.Password = string.Empty;
            NavigateToChats();
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

    private void NavigateToChats()
    {
        Frame.Navigate(typeof(ShellPage));
        Frame.BackStack.Clear();
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

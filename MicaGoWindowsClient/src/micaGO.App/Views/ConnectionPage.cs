using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using MicaGo.App.Services;
using MicaGo.Core.Connection;
using MicaGo.Infrastructure.Connection;

namespace MicaGo.App.Views;

public sealed class ConnectionPage : Page
{
    private readonly TextBlock _subtitle = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap, Opacity = 0.72 };
    private readonly TextBlock _pairingLabel = new() { FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold };
    private readonly TextBox _pairingBox = new() { MinHeight = 42, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock _tokenNote = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap, Opacity = 0.72 };
    private readonly Button _connectButton = new() { MinWidth = 104, VerticalAlignment = VerticalAlignment.Top, IsEnabled = false };
    private readonly Border _statusPanel = new() { Padding = new Thickness(12, 8, 12, 8), CornerRadius = new CornerRadius(6), Visibility = Visibility.Collapsed };
    private readonly TextBlock _statusText = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock _phaseText = new() { FontSize = 12, Opacity = 0.72 };
    private CancellationTokenSource? _connectionCancellation;
    private bool _restoreAttempted;

    public ConnectionPage()
    {
        Content = BuildContent();
        _pairingBox.TextChanged += PairingBox_TextChanged;
        _connectButton.Click += ConnectButton_Click;
        Loaded += ConnectionPage_Loaded;
        Unloaded += ConnectionPage_Unloaded;
    }

    private UIElement BuildContent()
    {
        _statusPanel.Child = _statusText;
        var heading = new StackPanel { Spacing = 4 };
        heading.Children.Add(new TextBlock { Text = "micaGO", FontSize = 24, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        heading.Children.Add(_subtitle);

        var top = new Grid { ColumnSpacing = 16 };
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.Children.Add(heading);
        Grid.SetColumn(_connectButton, 1);
        top.Children.Add(_connectButton);

        var input = new StackPanel { Spacing = 8 };
        input.Children.Add(_pairingLabel);
        input.Children.Add(_pairingBox);
        input.Children.Add(_tokenNote);

        var cardContent = new StackPanel
        {
            Width = 520,
            MaxWidth = 520,
            Spacing = 16,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        cardContent.Children.Add(top);
        cardContent.Children.Add(input);
        cardContent.Children.Add(_statusPanel);
        cardContent.Children.Add(_phaseText);

        var root = new Grid
        {
            Padding = new Thickness(28, 24, 28, 24),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
        };
        root.Children.Add(cardContent);
        return root;
    }

    private async void ConnectionPage_Loaded(object sender, RoutedEventArgs e)
    {
        if (_restoreAttempted) return;
        _restoreAttempted = true;
        await AppServices.Current.Cache.InitializeAsync();
        var language = await AppServices.Current.Cache.GetSettingAsync("settings.language");
        if (!string.IsNullOrWhiteSpace(language)) AppServices.Current.Localization.SetLanguage(language);
        ApplyText();
        await RestoreConnectionAsync();
    }

    private void ApplyText()
    {
        var l = AppServices.Current.Localization;
        _subtitle.Text = l["connSubtitle"];
        _pairingLabel.Text = l["connPairingJson"];
        _pairingBox.PlaceholderText = l["connPlaceholder"];
        _tokenNote.Text = l["connTokenNote"];
        _connectButton.Content = l["connConnect"];
    }

    private async Task RestoreConnectionAsync()
    {
        var l = AppServices.Current.Localization;
        SetBusy(true, l["connChecking"]);
        _connectionCancellation = new CancellationTokenSource(TimeSpan.FromSeconds(8));
        try
        {
            if (await AppServices.Current.Connection.TryRestoreAsync(_connectionCancellation.Token)) { App.ShowMainWindow(); return; }
            ShowStatus(l["connPaste"]);
        }
        catch (OperationCanceledException) { ShowStatus(l["connTimeout"]); }
        catch (Exception exception) { ShowStatus(string.Format(l["connRestoreFailed"], SafeMessage(exception))); }
        finally { SetBusy(false, string.Empty); }
    }

    private async void ConnectButton_Click(object sender, RoutedEventArgs e)
    {
        _connectionCancellation?.Cancel();
        _connectionCancellation = new CancellationTokenSource();
        SetBusy(true, AppServices.Current.Localization["connTesting"]);
        _statusPanel.Visibility = Visibility.Collapsed;
        var connected = false;
        try
        {
            await AppServices.Current.Connection.ConnectPairingJsonAsync(_pairingBox.Text, _connectionCancellation.Token);
            connected = true;
        }
        catch (PairingPayloadException exception) { ShowStatus(exception.Message); }
        catch (ConnectionException exception) { ShowStatus(exception.Message); }
        catch (Exception exception) when (exception is not OperationCanceledException) { ShowStatus($"Connection failed: {SafeMessage(exception)}"); }
        finally { if (!connected) SetBusy(false, string.Empty); }

        if (!connected) return;
        _pairingBox.Text = string.Empty;
        try
        {
            App.ShowMainWindow();
        }
        catch (Exception exception)
        {
            App.ReportStartupFailure(exception);
            ShowStatus($"Connected, but the chat interface could not be opened: {SafeMessage(exception)}");
            SetBusy(false, string.Empty);
        }
    }

    private void PairingBox_TextChanged(object sender, TextChangedEventArgs e) =>
        _connectButton.IsEnabled = _pairingBox.IsEnabled && !string.IsNullOrWhiteSpace(_pairingBox.Text);

    private void SetBusy(bool busy, string phase)
    {
        _pairingBox.IsEnabled = !busy;
        _connectButton.IsEnabled = !busy && !string.IsNullOrWhiteSpace(_pairingBox.Text);
        _phaseText.Text = phase;
    }

    private void ShowStatus(string message) { _statusText.Text = message; _statusPanel.Visibility = Visibility.Visible; }

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

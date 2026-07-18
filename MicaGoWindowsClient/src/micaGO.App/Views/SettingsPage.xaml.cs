using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using MicaGo.App.Services;
using MicaGo.Core.Connection;

namespace MicaGo.App.Views;

public sealed partial class SettingsPage : Page
{
    public SettingsPage()
    {
        InitializeComponent();
        Loaded += SettingsPage_Loaded;
    }

    private void SettingsPage_Loaded(object sender, RoutedEventArgs e)
    {
        var connection = AppServices.Current.Connection;
        ConnectionTitle.Text = connection.Profile?.ServerName ?? "micaGO server";
        if (connection.ActiveEndpoint is { } active)
        {
            var kind = active.Endpoint.Kind == EndpointKind.Lan ? "LAN" : "Public";
            ConnectionSubtitle.Text = $"{kind} · {active.Endpoint.BaseUrl} · {active.Latency.TotalMilliseconds:0} ms";
        }
        else
        {
            ConnectionSubtitle.Text = "Not connected";
        }
    }

    private void BackButton_Click(object sender, RoutedEventArgs e)
    {
        if (Frame.CanGoBack)
        {
            Frame.GoBack();
        }
    }

    private async void DisconnectButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = "Disconnect this PC?",
            Content = "The saved server route and token will be removed from Windows Credential Manager.",
            PrimaryButtonText = "Disconnect",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary)
        {
            return;
        }

        await AppServices.Current.Connection.DisconnectAsync();
        Frame.Navigate(typeof(ConnectionPage));
        Frame.BackStack.Clear();
    }
}

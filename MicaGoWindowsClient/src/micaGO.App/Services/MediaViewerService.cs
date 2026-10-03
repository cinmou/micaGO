using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using MicaGo.Core.Models;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.Storage.Streams;

namespace MicaGo.App.Services;

public static class MediaViewerService
{
    private static void EnsureAccess()
    {
        if (AppServices.Current.Connection.TokenRejected || !AppServices.Current.Media.AccessAllowed)
            throw new MicaGo.Infrastructure.Api.MicaGoApiException("Pair again to access media.", 401);
    }

    public static async Task ShowAsync(XamlRoot root, Message message, Attachment selected)
    {
        EnsureAccess();
        var messages = await AppServices.Current.Cache.GetMessagesAsync(message.ChatId, 1000);
        EnsureAccess();
        var media = messages.SelectMany(row => row.Media).Where(item => item.IsImage || item.IsVideo || item.IsAudio).ToList();
        if (media.Count == 0) media.Add(selected);
        var index = Math.Max(0, media.FindIndex(item => item.Id == selected.Id));
        var host = new Grid { MinWidth = 480, Height = 420 };
        var l = AppServices.Current.Localization;
        var dialog = new ContentDialog { XamlRoot = root, Title = selected.FileName, Content = host,
            CloseButtonText = l["close"], PrimaryButtonText = l["saveAs"], SecondaryButtonText = l["openWith"] };
        MediaPlayer? activePlayer = null;
        var closed = false;
        var renderEpoch = 0;
        void Reject(object? sender, EventArgs args) => host.DispatcherQueue.TryEnqueue(() =>
        {
            closed = true; renderEpoch++;
            activePlayer?.Dispose(); activePlayer = null;
            host.Children.Clear(); dialog.Hide();
        });
        AppServices.Current.Connection.CredentialRejected += Reject;
        async Task RenderAsync()
        {
            EnsureAccess();
            var epoch = ++renderEpoch;
            activePlayer?.Dispose(); activePlayer = null;
            host.Children.Clear();
            var current = media[index]; dialog.Title = $"{current.FileName} · {index + 1}/{media.Count}";
            var api = AppServices.Current.Connection.Api!;
            var path = AppServices.Current.Media.TryGetPath(current.Id) ?? await AppServices.Current.Media.GetAsync(api, current.Id);
            var file = await StorageFile.GetFileFromPathAsync(path);
            EnsureAccess();
            if (closed || epoch != renderEpoch) return;
            if (current.IsImage)
            {
                using IRandomAccessStream stream = await file.OpenAsync(FileAccessMode.Read);
                var bitmap = new BitmapImage(); await bitmap.SetSourceAsync(stream);
                EnsureAccess(); if (closed || epoch != renderEpoch) return;
                host.Children.Add(new ScrollViewer { MinZoomFactor = 1, MaxZoomFactor = 6, ZoomMode = ZoomMode.Enabled,
                    Content = new Image { Source = bitmap, Stretch = Microsoft.UI.Xaml.Media.Stretch.Uniform } });
            }
            else
            {
                var player = new MediaPlayer { Source = MediaSource.CreateFromStorageFile(file), AutoPlay = true };
                activePlayer = player;
                var element = new MediaPlayerElement { AreTransportControlsEnabled = true };
                element.SetMediaPlayer(player); host.Children.Add(element);
                if (current.IsVideo) player.MediaFailed += async (_, _) =>
                {
                    try
                    {
                        EnsureAccess();
                        var playable = AppServices.Current.Media.TryGetPath(current.Id, playable: true)
                            ?? await AppServices.Current.Media.GetAsync(api, current.Id, playable: true);
                        var playableFile = await StorageFile.GetFileFromPathAsync(playable);
                        host.DispatcherQueue.TryEnqueue(() =>
                        {
                            if (closed || epoch != renderEpoch || !AppServices.Current.Media.AccessAllowed) return;
                            player.Source = MediaSource.CreateFromStorageFile(playableFile);
                        });
                    }
                    catch { }
                };
            }
            if (media.Count > 1)
            {
                var previous = new Button { Content = "‹", FontSize = 28, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center };
                var next = new Button { Content = "›", FontSize = 28, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
                async Task MoveAsync(int offset) { try { index = (index + offset + media.Count) % media.Count; await RenderAsync(); } catch { } }
                previous.Click += async (_, _) => await MoveAsync(-1); next.Click += async (_, _) => await MoveAsync(1);
                host.Children.Add(previous); host.Children.Add(next);
            }
        }
        try
        {
            await RenderAsync(); EnsureAccess(); if (closed) return;
            var result = await dialog.ShowAsync(); EnsureAccess();
            var chosen = media[index];
            if (result == ContentDialogResult.Primary) await SaveAsAsync(chosen);
            else if (result == ContentDialogResult.Secondary)
            {
                var path = AppServices.Current.Media.TryGetPath(chosen.Id) ?? await AppServices.Current.Media.GetAsync(AppServices.Current.Connection.Api!, chosen.Id);
                var file = await StorageFile.GetFileFromPathAsync(path); EnsureAccess();
                await Windows.System.Launcher.LaunchFileAsync(file);
            }
        }
        finally
        {
            closed = true; renderEpoch++;
            AppServices.Current.Connection.CredentialRejected -= Reject;
            activePlayer?.Dispose(); host.Children.Clear();
        }
    }

    private static async Task SaveAsAsync(Attachment attachment)
    {
        EnsureAccess();
        var picker = new FileSavePicker { SuggestedFileName = attachment.FileName };
        picker.FileTypeChoices.Add("File", [string.IsNullOrWhiteSpace(Path.GetExtension(attachment.FileName)) ? ".bin" : Path.GetExtension(attachment.FileName)]);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow));
        var destination = await picker.PickSaveFileAsync(); if (destination is null) return;
        EnsureAccess();
        var path = AppServices.Current.Media.TryGetPath(attachment.Id) ?? await AppServices.Current.Media.GetAsync(AppServices.Current.Connection.Api!, attachment.Id);
        var file = await StorageFile.GetFileFromPathAsync(path); EnsureAccess();
        await file.CopyAndReplaceAsync(destination);
    }
}

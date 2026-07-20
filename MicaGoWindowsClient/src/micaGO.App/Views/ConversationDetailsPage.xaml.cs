using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Navigation;
using MicaGo.App.Services;
using MicaGo.Core.Models;

namespace MicaGo.App.Views;

public sealed partial class ConversationDetailsPage : Page
{
    private ChatSummary? _chat;
    private ShellNavigationContext? _context;

    public ConversationDetailsPage() => InitializeComponent();

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _context = e.Parameter as ShellNavigationContext;
        _chat = _context?.Chat;
        if (_chat is null)
        {
            return;
        }

        var l = AppServices.Current.Localization;
        ParticipantsHeader.Text = l["participants"];
        ConversationHeader.Text = l["conversation"];
        MediaHeader.Text = l["sharedMedia"];
        MuteLabel.Text = l["mute"];
        PinLabel.Text = l["pin"];

        HeroAvatar.DisplayName = _chat.Title;
        HeroAvatar.ProfilePicture = Ui.Image(_chat.AvatarPath);
        TitleText.Text = _chat.Title;
        ServiceText.Text = _chat.ServiceLabel;

        var participants = new List<string>();
        foreach (var identity in _chat.Participants ?? [])
        {
            var contact = await AppServices.Current.Cache.ResolveContactAsync(identity);
            participants.Add(contact is null ? identity : $"{contact.DisplayName}  ·  {identity}");
        }
        ParticipantsList.ItemsSource = participants;

        MuteToggle.IsOn = await IsEnabledAsync("chat.muted.");
        PinToggle.IsOn = await IsEnabledAsync("chat.pinned.");

        var messages = await AppServices.Current.Cache.GetMessagesAsync(_chat.Id, 500);
        var items = messages
            .SelectMany(message => message.Media)
            .Where(item => (item.IsImage || item.IsVideo) && !item.IsStickerLike)
            .Take(12)
            .Select(item => new DetailsMediaItem(item))
            .ToArray();
        MediaList.ItemsSource = items;
        foreach (var item in items)
        {
            _ = LoadPreviewAsync(item);
        }
    }

    private async Task LoadPreviewAsync(DetailsMediaItem item)
    {
        var api = AppServices.Current.Connection.Api;
        if (api is null)
        {
            return;
        }
        try
        {
            var path = AppServices.Current.Media.TryGetPath(item.Attachment.Id, preview: true)
                ?? await AppServices.Current.Media.GetAsync(api, item.Attachment.Id, preview: true);
            var file = await Windows.Storage.StorageFile.GetFileFromPathAsync(path);
            using var stream = await file.OpenAsync(Windows.Storage.FileAccessMode.Read);
            var bitmap = new BitmapImage { DecodePixelWidth = 360 };
            await bitmap.SetSourceAsync(stream);
            item.PreviewBrush = new ImageBrush { ImageSource = bitmap, Stretch = Stretch.UniformToFill };
        }
        catch { }
    }

    private async Task<bool> IsEnabledAsync(string prefix) =>
        string.Equals(await AppServices.Current.Cache.GetSettingAsync(prefix + _chat!.Id), "1", StringComparison.Ordinal);

    private async void MuteToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (_chat is not null)
        {
            await AppServices.Current.Cache.SetSettingAsync("chat.muted." + _chat.Id, MuteToggle.IsOn ? "1" : "0");
        }
    }

    private async void PinToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (_chat is not null)
        {
            await AppServices.Current.Cache.SetSettingAsync("chat.pinned." + _chat.Id, PinToggle.IsOn ? "1" : "0");
        }
    }

    private void BackButton_Click(object sender, RoutedEventArgs e) => _context?.Host.ExitDetailMode();
}

public sealed class DetailsMediaItem : System.ComponentModel.INotifyPropertyChanged
{
    private Brush _previewBrush;

    public DetailsMediaItem(Attachment attachment)
    {
        Attachment = attachment;
        _previewBrush = Application.Current.Resources.TryGetValue("SubtleFillColorSecondaryBrush", out var value) && value is Brush brush
            ? brush
            : new SolidColorBrush(Microsoft.UI.Colors.Gray);
    }

    public Attachment Attachment { get; }
    public string Label => Attachment.FileName;

    public Brush PreviewBrush
    {
        get => _previewBrush;
        set
        {
            _previewBrush = value;
            PropertyChanged?.Invoke(this, new(nameof(PreviewBrush)));
        }
    }

    public event System.ComponentModel.PropertyChangedEventHandler? PropertyChanged;
}

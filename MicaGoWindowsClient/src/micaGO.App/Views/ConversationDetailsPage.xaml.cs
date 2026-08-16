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

        // Participants are a group-chat concept (Flutter's details sheet does
        // the same); a 1:1 contact shows its routes/handles instead.
        if (_chat.IsGroup && (_chat.Participants?.Count ?? 0) > 0)
        {
            var participants = new List<string>();
            foreach (var identity in _chat.Participants!)
            {
                var contact = await AppServices.Current.Cache.ResolveContactAsync(identity);
                participants.Add(contact is null ? identity : $"{contact.DisplayName}  ·  {identity}");
            }
            ParticipantsList.ItemsSource = participants;
        }
        else
        {
            ParticipantsHeader.Visibility = Visibility.Collapsed;
            ParticipantsCard.Visibility = Visibility.Collapsed;
        }

        MuteToggle.IsOn = await IsEnabledAsync("chat.muted.");
        PinToggle.IsOn = await IsEnabledAsync("chat.pinned.");
        await LoadRoutesCardAsync(l);

        var routes = _chat.RouteIds is { Count: > 0 } ? _chat.RouteIds : [_chat.Id];
        var messages = (await Task.WhenAll(routes.Select(route => AppServices.Current.Cache.GetMessagesAsync(route, 500))))
            .SelectMany(page => page).OrderByDescending(message => message.DateCreated).ToArray();
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

    private bool _loadingMergeToggle;
    private bool _loadingSendRoute;

    /// <summary>
    /// Merged-view opt-out (Flutter C68 beta): a 1:1 contact whose messages
    /// arrive over several routes can be split back into separate chats.
    /// </summary>
    private async Task LoadRoutesCardAsync(Services.LocalizationService l)
    {
        if (_chat is null || _chat.IsGroup) return;
        var mergeKey = "chat.mergeRoutes." + (_chat.ContactId ?? _chat.Id);
        var stored = await AppServices.Current.Cache.GetSettingAsync(mergeKey);
        var routes = _chat.RouteIds;
        RoutesHeader.Visibility = Visibility.Visible;
        RoutesCard.Visibility = Visibility.Visible;
        RoutesHeader.Text = l["routes"];
        MergeRoutesLabel.Text = l["mergeRoutes"];
        RoutesListText.Text = string.Join('\n',
            routes is { Count: > 0 } ? routes : [_chat.Participants?.FirstOrDefault() ?? _chat.Id]);
        // The merge toggle only matters when this contact actually has (or
        // had) more than one route.
        var toggleRelevant = (routes?.Count ?? 0) > 1 || stored == "0";
        MergeRoutesToggle.Visibility = toggleRelevant ? Visibility.Visible : Visibility.Collapsed;
        _loadingMergeToggle = true;
        MergeRoutesToggle.IsOn = stored != "0";
        _loadingMergeToggle = false;
        if (routes is { Count: > 1 })
        {
            SendRouteLabel.Text=l["sendUsing"];
            SendRouteLabel.Visibility=Visibility.Visible;
            SendRoutePicker.Visibility=Visibility.Visible;
            _loadingSendRoute=true;
            foreach(var route in routes)SendRoutePicker.Items.Add(new ComboBoxItem{Content=route,Tag=route});
            SendRoutePicker.SelectedIndex=Math.Max(0,routes.ToList().FindIndex(route=>route.Equals(_chat.PrimaryRouteId,StringComparison.OrdinalIgnoreCase)));
            _loadingSendRoute=false;
        }
    }

    private async void MergeRoutesToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (_loadingMergeToggle || _chat is null) return;
        var mergeKey = "chat.mergeRoutes." + (_chat.ContactId ?? _chat.Id);
        await AppServices.Current.Cache.SetSettingAsync(mergeKey, MergeRoutesToggle.IsOn ? "1" : "0");
        if (_context is not null) await _context.Host.RefreshContactsAsync();
    }

    private async void SendRoutePicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if(_loadingSendRoute||_chat is null||SendRoutePicker.SelectedItem is not ComboBoxItem { Tag:string route })return;
        await AppServices.Current.Cache.SetSettingAsync("chat.sendRoute."+(_chat.ContactId??_chat.Id),route);
        if(_context is not null)await _context.Host.RefreshContactsAsync();
    }

    private async Task<bool> IsEnabledAsync(string prefix) =>
        string.Equals(await AppServices.Current.Cache.GetSettingAsync(prefix + PreferenceKey), "1", StringComparison.Ordinal);

    private string PreferenceKey => string.IsNullOrWhiteSpace(_chat?.ContactId) ? _chat!.Id : "contact:" + _chat.ContactId.ToUpperInvariant();

    private async void MuteToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (_chat is not null)
        {
            await AppServices.Current.Cache.SetSettingAsync("chat.muted." + PreferenceKey, MuteToggle.IsOn ? "1" : "0");
        }
    }

    private async void PinToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (_chat is not null)
        {
            await AppServices.Current.Cache.SetSettingAsync("chat.pinned." + PreferenceKey, PinToggle.IsOn ? "1" : "0");
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

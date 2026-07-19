using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.UI.Xaml.Media.Imaging;
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
        base.OnNavigatedTo(e); _context=e.Parameter as ShellNavigationContext; _chat = _context?.Chat; if (_chat is null) return;
        var l=AppServices.Current.Localization; PageTitle.Text=l["details"];ParticipantsHeader.Text=l["participants"];ConversationHeader.Text=l["conversation"];MediaHeader.Text=l["sharedMedia"];MuteToggle.Header=l["mute"];PinToggle.Header=l["pin"];
        InitialsText.Text = _chat.Initials; TitleText.Text = _chat.Title; ServiceText.Text = _chat.ServiceLabel;
        var participants=new List<string>();foreach(var identity in _chat.Participants??[]){var contact=await AppServices.Current.Cache.ResolveContactAsync(identity);participants.Add(contact is null?identity:$"{contact.DisplayName}  ·  {identity}");}ParticipantsList.ItemsSource=participants;
        MuteToggle.IsOn = await IsEnabledAsync("chat.muted."); PinToggle.IsOn = await IsEnabledAsync("chat.pinned.");
        var messages = await AppServices.Current.Cache.GetMessagesAsync(_chat.Id, 500);
        var items=messages.SelectMany(message=>message.Media).Where(item=>(item.IsImage||item.IsVideo)&&!item.IsStickerLike).Take(12).Select(item=>new DetailsMediaItem(item)).ToArray();MediaList.ItemsSource=items;
        foreach(var item in items)_=LoadPreviewAsync(item);
    }
    private async Task LoadPreviewAsync(DetailsMediaItem item)
    {
        var api=AppServices.Current.Connection.Api;if(api is null)return;
        try{var path=AppServices.Current.Media.TryGetPath(item.Attachment.Id,preview:true)??await AppServices.Current.Media.GetAsync(api,item.Attachment.Id,preview:true);var file=await Windows.Storage.StorageFile.GetFileFromPathAsync(path);using var stream=await file.OpenAsync(Windows.Storage.FileAccessMode.Read);var bitmap=new BitmapImage{DecodePixelWidth=360};await bitmap.SetSourceAsync(stream);item.Preview=bitmap;}
        catch { }
    }
    private async Task<bool> IsEnabledAsync(string prefix) => string.Equals(await AppServices.Current.Cache.GetSettingAsync(prefix + _chat!.Id), "1", StringComparison.Ordinal);
    private async void MuteToggle_Toggled(object sender, RoutedEventArgs e) { if (_chat is not null) await AppServices.Current.Cache.SetSettingAsync("chat.muted." + _chat.Id, MuteToggle.IsOn ? "1" : "0"); }
    private async void PinToggle_Toggled(object sender, RoutedEventArgs e) { if (_chat is not null) await AppServices.Current.Cache.SetSettingAsync("chat.pinned." + _chat.Id, PinToggle.IsOn ? "1" : "0"); }
    private void BackButton_Click(object sender, RoutedEventArgs e) => _context?.Host.ExitDetailMode();
}

public sealed class DetailsMediaItem : System.ComponentModel.INotifyPropertyChanged
{
    private BitmapImage? _preview;
    public DetailsMediaItem(Attachment attachment) => Attachment=attachment;
    public Attachment Attachment { get; } public string Label=>Attachment.FileName;
    public BitmapImage? Preview{get=>_preview;set{_preview=value;PropertyChanged?.Invoke(this,new(nameof(Preview)));}}
    public event System.ComponentModel.PropertyChangedEventHandler? PropertyChanged;
}

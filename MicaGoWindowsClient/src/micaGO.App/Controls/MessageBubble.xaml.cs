using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using MicaGo.App.Services;
using MicaGo.Core.Models;
using Windows.Storage;
using Windows.Storage.Streams;

namespace MicaGo.App.Controls;

public sealed partial class MessageBubble : UserControl
{
    private const int ThumbnailCacheLimit = 64;
    private static readonly Dictionary<string, BitmapImage> ThumbnailCache = [];
    private static readonly LinkedList<string> ThumbnailLru = [];
    private static readonly object ThumbnailGate = new();
    private Message? _message;
    public MessageBubble()
    {
        InitializeComponent();
        DataContextChanged += OnDataContextChanged;
    }

    private void OnDataContextChanged(FrameworkElement sender, DataContextChangedEventArgs args)
    {
        if (args.NewValue is not Message message)
        {
            return;
        }

        _message = message;
        SeparatorChip.Visibility=message.IsSeparator?Visibility.Visible:Visibility.Collapsed;SeparatorText.Text=message.SeparatorLabel??string.Empty;Bubble.Visibility=message.IsSeparator?Visibility.Collapsed:Visibility.Visible;if(message.IsSeparator){Root.Margin=new Thickness(18,10,18,8);return;}
        VisualStateManager.GoToState(this, message.IsOutgoing ? "Outgoing" : "Incoming", false);
        AvatarColumn.Width=new GridLength(message.ReserveSenderAvatarSpace?28:0);
        Root.Margin=new Thickness(18,message.CompactWithPrevious?0.5:3,18,message.CompactWithNext?0.5:3);
        Bubble.CornerRadius=message.IsOutgoing?(message.ShowBubbleTail?new CornerRadius(18,18,4,18):new CornerRadius(18)):(message.ShowBubbleTail?new CornerRadius(18,18,18,4):new CornerRadius(18));

        SenderText.Text = message.SenderName ?? message.SenderIdentity ?? string.Empty;
        if (!message.IsOutgoing)
        {
            SenderText.Visibility = message.ShowSenderLabel&&!string.IsNullOrWhiteSpace(message.SenderName) ? Visibility.Visible : Visibility.Collapsed;
        }
        SenderAvatar.Visibility=message.ShowSenderAvatar?Visibility.Visible:Visibility.Collapsed;
        SenderAvatarInitials.Text=Initials(message.SenderName??message.SenderIdentity);SenderAvatarImage.Source=null;SenderAvatarInitials.Visibility=Visibility.Visible;
        if(message.ShowSenderAvatar&&!string.IsNullOrWhiteSpace(message.SenderAvatarPath))_ = LoadAvatarAsync(message);
        var visibleText = MessageSemantics.VisibleText(message.Text);
        if(message.IsPresentationSystem)visibleText=(message.GroupTitle??"Conversation updated")+(message.MergedSystemCount>1?$" · {message.MergedSystemCount} events":string.Empty);
        BodyText.Text = visibleText;
        BodyText.Visibility = string.IsNullOrWhiteSpace(visibleText) ? Visibility.Collapsed : Visibility.Visible;
        AttachmentText.Text = message.AttachmentLabel ?? string.Empty;
        AttachmentPanel.Visibility = string.IsNullOrWhiteSpace(message.AttachmentLabel) ? Visibility.Collapsed : Visibility.Visible;
        ConfigureAttachment(message.Media.FirstOrDefault());
        AttachmentText.Visibility=message.IsStickerOnly?Visibility.Collapsed:Visibility.Visible;
        UploadProgress.Value = message.UploadProgress;
        UploadProgress.Visibility = message.IsPending && message.DeliveryState == MessageDeliveryState.Sending ? Visibility.Visible : Visibility.Collapsed;
        FooterText.Text = FooterLabel(message);FooterText.Visibility=message.ShowFooter?Visibility.Visible:Visibility.Collapsed;
        EffectText.Text=message.EffectLabel??string.Empty;EffectText.Visibility=string.IsNullOrWhiteSpace(message.EffectLabel)?Visibility.Collapsed:Visibility.Visible;EffectText.HorizontalAlignment=message.IsOutgoing?HorizontalAlignment.Right:HorizontalAlignment.Left;
        ReplyText.Text=message.ReplyPreview??string.Empty;ReplyPanel.Visibility=string.IsNullOrWhiteSpace(message.ReplyPreview)?Visibility.Collapsed:Visibility.Visible;
        ReactionText.Text=string.Join(" ",message.Reactions??[]);ReactionText.Visibility=(message.Reactions?.Count??0)>0?Visibility.Visible:Visibility.Collapsed;
        if(message.IsBigEmoji){Bubble.Background=new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent);Bubble.BorderThickness=new Thickness(0);Bubble.Padding=new Thickness(2,3,2,3);BodyText.FontSize=visibleText.Length<=2?72:visibleText.Length<=5?56:48;BodyText.LineHeight=86;}
        else if(message.IsStickerOnly){Bubble.Background=new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent);Bubble.BorderThickness=new Thickness(0);Bubble.Padding=new Thickness(0);AttachmentPanel.Background=new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent);AttachmentPanel.Padding=new Thickness(0);}
        else{BodyText.FontSize=14;BodyText.LineHeight=20;Bubble.BorderThickness=new Thickness(1);Bubble.Padding=new Thickness(16,8,16,8);AttachmentPanel.Background=ThemeBrush("SubtleFillColorSecondaryBrush",Microsoft.UI.Colors.Transparent);AttachmentPanel.Padding=new Thickness(12);BodyText.Foreground=ThemeBrush("TextFillColorPrimaryBrush",Microsoft.UI.Colors.Black);}
        if(message.IsPresentationSystem){Bubble.HorizontalAlignment=HorizontalAlignment.Center;Bubble.Background=new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent);Bubble.BorderThickness=new Thickness(0);BodyText.Foreground=ThemeBrush("TextFillColorSecondaryBrush",Microsoft.UI.Colors.Gray);BodyText.FontSize=12;SenderAvatar.Visibility=Visibility.Collapsed;}
        _ = LoadMediaAsync(message);
    }

    private async Task LoadMediaAsync(Message message)
    {
        MediaImage.Visibility = Visibility.Collapsed; AttachmentIcon.Visibility = Visibility.Visible;
        var attachment = message.Media.FirstOrDefault();
        if (attachment is null || (!attachment.IsImage && !attachment.IsVideo)) return;
        lock(ThumbnailGate) if(ThumbnailCache.TryGetValue(attachment.Id,out var cached)){TouchThumbnail(attachment.Id);MediaImage.Source=cached;MediaImage.Visibility=Visibility.Visible;AttachmentIcon.Visibility=Visibility.Collapsed;return;}
        try
        {
            var path = AppServices.Current.Media.TryGetPath(attachment.Id, preview: true)
                ?? await AppServices.Current.Media.GetAsync(AppServices.Current.Connection.Api!, attachment.Id, preview: true);
            if (_message?.Id != message.Id) return;
            var file = await StorageFile.GetFileFromPathAsync(path); using IRandomAccessStream stream = await file.OpenAsync(FileAccessMode.Read);
            var bitmap = new BitmapImage { DecodePixelWidth = 900 }; await bitmap.SetSourceAsync(stream); MediaImage.Source = bitmap;
            lock(ThumbnailGate){ThumbnailCache[attachment.Id]=bitmap;TouchThumbnail(attachment.Id);while(ThumbnailCache.Count>ThumbnailCacheLimit&&ThumbnailLru.First is{} oldest){ThumbnailLru.RemoveFirst();ThumbnailCache.Remove(oldest.Value);}}
            MediaImage.Visibility = Visibility.Visible; AttachmentIcon.Visibility = Visibility.Collapsed;
        }
        catch { }
    }

    private static void TouchThumbnail(string key){ThumbnailLru.Remove(key);ThumbnailLru.AddLast(key);}

    private void ConfigureAttachment(Attachment? attachment)
    {
        if(attachment is null)return;
        if(attachment.IsStickerLike){AttachmentIcon.Visibility=Visibility.Collapsed;return;}
        AttachmentIcon.Visibility=Visibility.Visible;
        if(attachment.IsVoiceMessage){AttachmentIcon.Glyph="\uE767";AttachmentText.Text="Voice message";}
        else if(attachment.IsAudio){AttachmentIcon.Glyph="\uE8D6";AttachmentText.Text=attachment.FileName;}
        else if(attachment.IsVideo){AttachmentIcon.Glyph="\uE768";AttachmentText.Text=attachment.FileName;}
        else if(attachment.IsLocation){AttachmentIcon.Glyph="\uE707";AttachmentText.Text="Shared location";}
        else if(attachment.IsLinkPreview){AttachmentIcon.Glyph="\uE71B";AttachmentText.Text=attachment.FileName;}
        else if(attachment.IsImage){AttachmentIcon.Glyph="\uEB9F";AttachmentText.Text=attachment.FileName;}
        else{AttachmentIcon.Glyph="\uE8B7";AttachmentText.Text=attachment.FileName;}
    }

    private async Task LoadAvatarAsync(Message message)
    {
        try{var file=await StorageFile.GetFileFromPathAsync(message.SenderAvatarPath!);using var stream=await file.OpenAsync(FileAccessMode.Read);var bitmap=new BitmapImage{DecodePixelWidth=64};await bitmap.SetSourceAsync(stream);if(_message?.PresentationKey!=message.PresentationKey)return;SenderAvatarImage.Source=bitmap;SenderAvatarInitials.Visibility=Visibility.Collapsed;}catch{}
    }

    private static string Initials(string? value){var parts=(value??string.Empty).Split(' ',StringSplitOptions.RemoveEmptyEntries|StringSplitOptions.TrimEntries);return parts.Length==0?"?":parts.Length==1?parts[0][..1].ToUpperInvariant():string.Concat(parts[0][..1],parts[1][..1]).ToUpperInvariant();}

    private static Microsoft.UI.Xaml.Media.Brush ThemeBrush(string key, Windows.UI.Color fallback) =>
        Application.Current.Resources.TryGetValue(key,out var value)&&value is Microsoft.UI.Xaml.Media.Brush brush
            ? brush
            : new Microsoft.UI.Xaml.Media.SolidColorBrush(fallback);

    private static string FooterLabel(Message message)
    {
        var language=AppServices.Current.Localization.Language;var labels=language switch
        {
            "zh-Hans"=>new[]{"发送中","已发送","已送达","已读","发送失败"},
            "zh-Hant"=>new[]{"傳送中","已傳送","已送達","已讀","傳送失敗"},
            _=>new[]{"Sending","Sent","Delivered","Read","Failed to send"}
        };
        var state=message.DeliveryState switch{MessageDeliveryState.Sending=>labels[0],MessageDeliveryState.Sent=>labels[1],MessageDeliveryState.Delivered=>labels[2],MessageDeliveryState.Read=>$"{labels[3]} · {message.SentAt}",MessageDeliveryState.Failed=>labels[4],_=>message.SentAt};
        if(message.IsEdited)state+=" · "+(language=="zh-Hans"?"已编辑":language=="zh-Hant"?"已編輯":"Edited");return state;
    }

    private async void AttachmentPanel_Tapped(object sender, Microsoft.UI.Xaml.Input.TappedRoutedEventArgs e)
    {
        var attachment = _message?.Media.FirstOrDefault(); var api = AppServices.Current.Connection.Api;
        if (attachment is null || api is null) return;
        try
        {
            await MediaViewerService.ShowAsync(XamlRoot,_message!,attachment);
        }
        catch { }
    }
}

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using MicaGo.Core.Models;
using Windows.Media.Core;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.Storage.Streams;

namespace MicaGo.App.Services;

public static class MediaViewerService
{
    public static async Task ShowAsync(XamlRoot root,Message message,Attachment selected)
    {
        var messages=await AppServices.Current.Cache.GetMessagesAsync(message.ChatId,1000);var media=messages.SelectMany(row=>row.Media).Where(item=>item.IsImage||item.IsVideo||item.IsAudio).ToList();var index=Math.Max(0,media.FindIndex(item=>item.Id==selected.Id));if(media.Count==0)media.Add(selected);
        var host=new Grid{MinWidth=720,MinHeight=520};var dialog=new ContentDialog{XamlRoot=root,Title=selected.FileName,Content=host,CloseButtonText="Close"};
        dialog.PrimaryButtonText="Save as";dialog.SecondaryButtonText="Open with";
        async Task RenderAsync()
        {
            host.Children.Clear();var current=media[index];dialog.Title=$"{current.FileName} · {index+1}/{media.Count}";
            if(current.IsImage)
            {
                var path=AppServices.Current.Media.TryGetPath(current.Id)??await AppServices.Current.Media.GetAsync(AppServices.Current.Connection.Api!,current.Id);var file=await StorageFile.GetFileFromPathAsync(path);using IRandomAccessStream stream=await file.OpenAsync(FileAccessMode.Read);var bitmap=new BitmapImage();await bitmap.SetSourceAsync(stream);host.Children.Add(new ScrollViewer{MinZoomFactor=1,MaxZoomFactor=6,ZoomMode=ZoomMode.Enabled,Content=new Image{Source=bitmap,Stretch=Microsoft.UI.Xaml.Media.Stretch.Uniform}});
            }
            else
            {
                var path=AppServices.Current.Media.TryGetPath(current.Id)??await AppServices.Current.Media.GetAsync(AppServices.Current.Connection.Api!,current.Id);var player=new MediaPlayerElement{AreTransportControlsEnabled=true,AutoPlay=true};player.Source=MediaSource.CreateFromStorageFile(await StorageFile.GetFileFromPathAsync(path));host.Children.Add(player);
                if(current.IsVideo){player.MediaPlayer.MediaFailed+=async(_,_)=>{try{var playable=AppServices.Current.Media.TryGetPath(current.Id,playable:true)??await AppServices.Current.Media.GetAsync(AppServices.Current.Connection.Api!,current.Id,playable:true);player.DispatcherQueue.TryEnqueue(async()=>player.Source=MediaSource.CreateFromStorageFile(await StorageFile.GetFileFromPathAsync(playable)));}catch{}};}
            }
            if(media.Count>1){var previous=new Button{Content="‹",FontSize=28,HorizontalAlignment=HorizontalAlignment.Left,VerticalAlignment=VerticalAlignment.Center};var next=new Button{Content="›",FontSize=28,HorizontalAlignment=HorizontalAlignment.Right,VerticalAlignment=VerticalAlignment.Center};previous.Click+=async(_,_)=>{index=(index-1+media.Count)%media.Count;await RenderAsync();};next.Click+=async(_,_)=>{index=(index+1)%media.Count;await RenderAsync();};host.Children.Add(previous);host.Children.Add(next);}
        }
        await RenderAsync();var result=await dialog.ShowAsync();var chosen=media[index];if(result==ContentDialogResult.Primary)await SaveAsAsync(chosen);else if(result==ContentDialogResult.Secondary){var path=AppServices.Current.Media.TryGetPath(chosen.Id)??await AppServices.Current.Media.GetAsync(AppServices.Current.Connection.Api!,chosen.Id);await Windows.System.Launcher.LaunchFileAsync(await StorageFile.GetFileFromPathAsync(path));}
    }

    private static async Task SaveAsAsync(Attachment attachment)
    {
        var picker=new FileSavePicker{SuggestedFileName=attachment.FileName};picker.FileTypeChoices.Add("File",[string.IsNullOrWhiteSpace(Path.GetExtension(attachment.FileName))?".bin":Path.GetExtension(attachment.FileName)]);WinRT.Interop.InitializeWithWindow.Initialize(picker,WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow));var destination=await picker.PickSaveFileAsync();if(destination is null)return;var path=AppServices.Current.Media.TryGetPath(attachment.Id)??await AppServices.Current.Media.GetAsync(AppServices.Current.Connection.Api!,attachment.Id);await (await StorageFile.GetFileFromPathAsync(path)).CopyAndReplaceAsync(destination);
    }
}

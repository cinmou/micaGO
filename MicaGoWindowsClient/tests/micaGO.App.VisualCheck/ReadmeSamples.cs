using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using MicaGo.App.Controls;
using MicaGo.App.Services;
using MicaGo.Core.Models;

namespace MicaGo.App.Views;

public sealed partial class ShellPage
{
    internal void LoadReadmeSamples(bool settings)
    {
        // Detach startup before attaching to a window: no profile, cache or API reads.
        Loaded-=ShellPage_Loaded;ApplyLocalizedText();
        var chat=new ChatSummary("demo-maya","Maya Chen","See you there 👋","10:36",0,"MC",ServiceLabel:"iMessage",CanSendText:true,CanSendAttachments:true);
        ChatList.ItemsSource=new[]{chat,
            new ChatSummary("demo-weekend","Weekend plans","Sam: I'll bring the snacks!","10:22",3,"WP",IsGroup:true,HasUnread:true),
            new ChatSummary("demo-alex","Alex Rivera","Thanks for sharing the playlist.","09:40",0,"AR"),
            new ChatSummary("demo-studio","Design studio","The new colors look great.","Yesterday",0,"DS",IsGroup:true),
            new ChatSummary("demo-noah","Noah Park","See you next week!","Yesterday",0,"NP")};
        ChatList.SelectedItem=chat;ThreadTitle.Text=chat.Title;ThreadSubtitle.Text="Today, 10:36";ThreadAvatar.DisplayName=chat.Title;
        ApplyConnectionStatusVisibility(false);EmptyState.Visibility=Visibility.Collapsed;
        Composer.IsEnabled=true;EmojiButton.IsEnabled=true;AttachButton.IsEnabled=true;SendButton.IsEnabled=false;
        JumpToBottomButton.Visibility=Visibility.Collapsed;
        var samples=new[]{
            ("Found a little café near the park. Want to go on Saturday?",false),
            ("Sounds good! Does 10:30 work for you?",true),
            ("Perfect. I'll bring the camera 📷",false),
            ("Let's take the riverside route afterward.",true),
            ("Great idea. Coffee, photos, and a long walk.",false),
            ("See you there 👋",true)};
        var start=new DateTimeOffset(DateTime.Today.AddHours(10).AddMinutes(30));
        var messages=samples.Select((sample,index)=>new Message($"demo-message-{index}",chat.Id,sample.Item1,$"10:{31+index}",sample.Item2,
            MessageDeliveryState.Read,DateCreated:start.AddMinutes(index).ToUnixTimeMilliseconds())).ToArray();
        MessageList.ItemsSource=ThreadPresentation.Build(messages,false,"en").Select(message=>new MessageRow(message)).ToArray();
        if(!settings)return;
        SettingsNavigationList.SelectionChanged-=SettingsNavigationList_SelectionChanged;
        SettingsNavigationList.SelectedIndex=1;
        ChatSidebar.Visibility=Visibility.Collapsed;SettingsSidebar.Visibility=Visibility.Visible;
        ConversationPane.Visibility=Visibility.Collapsed;DetailFrame.Visibility=Visibility.Visible;
        var appearance=new SettingsPage();appearance.LoadAppearanceVisualSample();DetailFrame.Content=appearance;
    }
}

internal static class ReadmeCapture
{
    private static readonly List<Window> Windows=[];
    internal static void Run()
    {
        AppServices.Current.Localization.SetLanguage("en");
        foreach(var (settings,dark) in new[]{(false,false),(false,true),(true,false)})
        {
            var shell=new ShellPage();shell.LoadReadmeSamples(settings);
            var root=new Grid{RequestedTheme=dark?ElementTheme.Dark:ElementTheme.Light};
            shell.RequestedTheme=root.RequestedTheme;
            AppServices.Current.Localization.ApplyTypography(root);
            root.RowDefinitions.Add(new(){Height=new GridLength(32)});
            root.RowDefinitions.Add(new(){Height=new GridLength(1,GridUnitType.Star)});
            var titleBar=new Grid();titleBar.Children.Add(TitleBarBrand.Create());root.Children.Add(titleBar);
            Grid.SetRow(shell,1);root.Children.Add(shell);
            var window=new Window{Title="micaGO",Content=root,SystemBackdrop=new MicaBackdrop()};
            window.AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory,"Assets","micaGO.ico"));
            if(Microsoft.UI.Windowing.AppWindowTitleBar.IsCustomizationSupported()) {
                window.ExtendsContentIntoTitleBar=true;window.SetTitleBar(titleBar);
                window.AppWindow.TitleBar.PreferredHeightOption=Microsoft.UI.Windowing.TitleBarHeightOption.Standard;
                window.AppWindow.TitleBar.ButtonForegroundColor=dark?Microsoft.UI.Colors.White:Microsoft.UI.Colors.Black;
                window.AppWindow.TitleBar.ButtonBackgroundColor=Microsoft.UI.Colors.Transparent;
                window.AppWindow.TitleBar.ButtonInactiveBackgroundColor=Microsoft.UI.Colors.Transparent;
            }
            window.AppWindow.Resize(new Windows.Graphics.SizeInt32(1680,1120));
            Windows.Add(window);window.Activate();
        }
    }
}

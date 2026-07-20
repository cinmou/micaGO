using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using MicaGo.App.Services;
using MicaGo.Core.Connection;

namespace MicaGo.App.Views;

public sealed partial class SettingsPage : Page
{
    private bool _loading = true;
    private ShellNavigationContext? _context;
    public SettingsPage() { InitializeComponent(); Loaded += SettingsPage_Loaded; }
    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _context=e.Parameter as ShellNavigationContext;
        ApplySection(_context?.Section ?? "general");
    }
    private async void SettingsPage_Loaded(object sender, RoutedEventArgs e)
    {
        var services=AppServices.Current; var connection=services.Connection;
        ConnectionTitle.Text=connection.Profile?.ServerName??"micaGO server";
        ConnectionSubtitle.Text=connection.ActiveEndpoint is { } active ? $"{(active.Endpoint.Kind==EndpointKind.Lan?"LAN":"Public")} · {active.Endpoint.BaseUrl} · {active.Latency.TotalMilliseconds:0} ms" : "Not connected";
        NotificationToggle.IsOn=(await services.Cache.GetSettingAsync("settings.notifications"))!="false";
        TrayToggle.IsOn=(await services.Cache.GetSettingAsync("settings.tray"))=="true";
        var theme=await services.Cache.GetSettingAsync("settings.theme")??"system"; ThemePicker.SelectedIndex=theme=="light"?1:theme=="dark"?2:0;
        var language=await services.Cache.GetSettingAsync("settings.language")??"system"; LanguagePicker.SelectedIndex=language=="en"?1:language=="zh-Hans"?2:language=="zh-Hant"?3:0;
        await services.Appearance.InitializeAsync();
        BubbleFollowSystemToggle.IsOn=services.Appearance.BubbleFollowsSystem;
        BubbleColorPicker.Color=services.Appearance.BubbleColor;
        BubbleColorButton.Visibility=services.Appearance.BubbleFollowsSystem?Visibility.Collapsed:Visibility.Visible;
        TwemojiFlagsToggle.IsOn=services.Appearance.TwemojiFlagsEnabled;
        UpdateBackgroundStatus();
        _loading=false;services.Notifications.Enabled=NotificationToggle.IsOn;ApplyText();ApplySection(_context?.Section??"general");
    }
    private void ApplySettings(){var s=AppServices.Current;s.Notifications.Enabled=NotificationToggle.IsOn;var lang=LanguagePicker.SelectedIndex switch{1=>"en",2=>"zh-Hans",3=>"zh-Hant",_=>"system"};s.Localization.SetLanguage(lang);var root=App.MainWindow.Content as FrameworkElement;if(root is not null)root.RequestedTheme=ThemePicker.SelectedIndex switch{1=>ElementTheme.Light,2=>ElementTheme.Dark,_=>ElementTheme.Default};ApplyText();}
    private void ApplyText(){var l=AppServices.Current.Localization;ConnectionHeader.Text=l["connection"];BehaviorHeader.Text=l["notifications"];NotificationLabel.Text=l["notify"];TrayLabel.Text=l["tray"];AppearanceHeader.Text=l["appearance"];ThemeLabel.Text=l["theme"];LanguageLabel.Text=l["language"];TwemojiFlagsLabel.Text=l["twemojiFlags"];TwemojiFlagsDescription.Text=l["twemojiFlagsDescription"];TwemojiAttribution.Text=l["twemojiAttribution"];TwemojiDisclaimer.Text=l["twemojiDisclaimer"];ChatBackgroundLabel.Text=l["chatBackground"];ChooseBackgroundButton.Content=l["choose"];ClearBackgroundButton.Content=l["removeBackground"];BubbleColorLabel.Text=l["bubbleColor"];BubbleFollowSystemToggle.Header=l["followSystemAccent"];BubbleColorButton.Content=l["choose"];ContactsHeader.Text=l["contacts"];ContactsHint.Text=l["contactsHint"];ImportVcfLabel.Text=l["importVcf"];ImportVcfButton.Content=l["chooseVcf"];ClearVcfButton.Content=l["clearContacts"];StorageHeader.Text=l["cache"];ClearCacheHint.Text=l["clearCache"];ClearCacheButton.Content=l["clearCacheButton"];UpdateBackgroundStatus();}
    private async void NotificationToggle_Toggled(object sender,RoutedEventArgs e){if(_loading)return;await AppServices.Current.Cache.SetSettingAsync("settings.notifications",NotificationToggle.IsOn?"true":"false");ApplySettings();}
    private async void TrayToggle_Toggled(object sender,RoutedEventArgs e){if(_loading)return;await App.SetTrayEnabledAsync(TrayToggle.IsOn);}
    private async void ThemePicker_SelectionChanged(object sender,SelectionChangedEventArgs e){if(_loading)return;await AppServices.Current.Cache.SetSettingAsync("settings.theme",ThemePicker.SelectedIndex switch{1=>"light",2=>"dark",_=>"system"});ApplySettings();}
    private async void LanguagePicker_SelectionChanged(object sender,SelectionChangedEventArgs e){if(_loading)return;await AppServices.Current.Cache.SetSettingAsync("settings.language",LanguagePicker.SelectedIndex switch{1=>"en",2=>"zh-Hans",3=>"zh-Hant",_=>"system"});ApplySettings();}
    private async void ChooseBackgroundButton_Click(object sender,RoutedEventArgs e)
    {
        var picker=new Windows.Storage.Pickers.FileOpenPicker();
        foreach(var extension in new[]{".png",".jpg",".jpeg",".bmp",".gif"})picker.FileTypeFilter.Add(extension);
        WinRT.Interop.InitializeWithWindow.Initialize(picker,WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow));
        var file=await picker.PickSingleFileAsync();if(file is null)return;
        await AppServices.Current.Appearance.SetChatBackgroundAsync(file.Path);UpdateBackgroundStatus();
        if(_context is not null)await _context.Host.RefreshAppearanceAsync();
    }
    private async void ClearBackgroundButton_Click(object sender,RoutedEventArgs e){await AppServices.Current.Appearance.ClearChatBackgroundAsync();UpdateBackgroundStatus();if(_context is not null)await _context.Host.RefreshAppearanceAsync();}
    private async void BubbleFollowSystemToggle_Toggled(object sender,RoutedEventArgs e){if(_loading)return;BubbleColorButton.Visibility=BubbleFollowSystemToggle.IsOn?Visibility.Collapsed:Visibility.Visible;await AppServices.Current.Appearance.SetBubbleFollowsSystemAsync(BubbleFollowSystemToggle.IsOn);if(_context is not null)await _context.Host.RefreshAppearanceAsync();}
    private async void BubbleColorPicker_ColorChanged(ColorPicker sender,ColorChangedEventArgs args){if(_loading||BubbleFollowSystemToggle.IsOn)return;await AppServices.Current.Appearance.SetBubbleColorAsync(args.NewColor);if(_context is not null)await _context.Host.RefreshAppearanceAsync();}
    private async void TwemojiFlagsToggle_Toggled(object sender,RoutedEventArgs e){if(_loading)return;await AppServices.Current.Appearance.SetTwemojiFlagsEnabledAsync(TwemojiFlagsToggle.IsOn);if(_context is not null)await _context.Host.RefreshAppearanceAsync();}
    private void UpdateBackgroundStatus(){if(ChatBackgroundStatus is null)return;var l=AppServices.Current.Localization;var custom=!string.IsNullOrWhiteSpace(AppServices.Current.Appearance.ChatBackgroundPath)&&File.Exists(AppServices.Current.Appearance.ChatBackgroundPath);ChatBackgroundStatus.Text=l[custom?"customBackground":"defaultMicaBackground"];ClearBackgroundButton.IsEnabled=custom;}
    private async void ImportVcfButton_Click(object sender,RoutedEventArgs e)
    {
        var picker=new Windows.Storage.Pickers.FileOpenPicker();picker.FileTypeFilter.Add(".vcf");
        WinRT.Interop.InitializeWithWindow.Initialize(picker,WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow));
        var files=await picker.PickMultipleFilesAsync();if(files.Count==0)return;
        ImportVcfButton.IsEnabled=false;VcfImportStatus.Text=AppServices.Current.Localization["importingVcf"];
        try{var contacts=0;var identities=0;var skipped=0;foreach(var file in files){var result=await AppServices.Current.VcfContacts.ImportAsync(file.Path);contacts+=result.ContactCount;identities+=result.IdentityCount;skipped+=result.SkippedCards;}if(_context is not null)await _context.Host.RefreshContactsAsync();VcfImportStatus.Text=string.Format(AppServices.Current.Localization["vcfImported"],contacts,identities,skipped);}
        catch(Exception exception){VcfImportStatus.Text=string.Format(AppServices.Current.Localization["vcfImportFailed"],exception.Message);}
        finally{ImportVcfButton.IsEnabled=true;}
    }
    private async void ClearVcfButton_Click(object sender,RoutedEventArgs e)
    {
        var l=AppServices.Current.Localization;var dialog=new ContentDialog{XamlRoot=XamlRoot,Title=l["clearContactsTitle"],Content=l["clearContactsConfirm"],PrimaryButtonText=l["clearContacts"],CloseButtonText=l["cancel"],DefaultButton=ContentDialogButton.Close};
        if(await dialog.ShowAsync()!=ContentDialogResult.Primary)return;
        ImportVcfButton.IsEnabled=false;ClearVcfButton.IsEnabled=false;
        try{await AppServices.Current.VcfContacts.ClearAllAsync();if(_context is not null)await _context.Host.RefreshContactsAsync();VcfImportStatus.Text=l["contactsCleared"];}
        finally{ImportVcfButton.IsEnabled=true;ClearVcfButton.IsEnabled=true;}
    }
    private async void ClearCacheButton_Click(object sender,RoutedEventArgs e){await AppServices.Current.Cache.ClearAsync();await AppServices.Current.Media.ClearAsync();}
    private void ApplySection(string section){GeneralSection.Visibility=section=="general"?Visibility.Visible:Visibility.Collapsed;ContactsSection.Visibility=section=="contacts"?Visibility.Visible:Visibility.Collapsed;StorageSection.Visibility=section=="storage"?Visibility.Visible:Visibility.Collapsed;}
    private async void DisconnectButton_Click(object sender,RoutedEventArgs e){var d=new ContentDialog{XamlRoot=XamlRoot,Title="Disconnect this PC?",Content="The saved server route and token will be removed from Windows Credential Manager.",PrimaryButtonText="Disconnect",CloseButtonText="Cancel",DefaultButton=ContentDialogButton.Close};if(await d.ShowAsync()!=ContentDialogResult.Primary)return;await AppServices.Current.Connection.DisconnectAsync();_context?.Host.NavigateToConnection();}
}

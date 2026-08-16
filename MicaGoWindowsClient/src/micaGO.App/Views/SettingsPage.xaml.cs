using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using MicaGo.App.Services;
using MicaGo.Core.Connection;
using MicaGo.Core.Models;

namespace MicaGo.App.Views;

public sealed partial class SettingsPage : Page
{
    private bool _loading = true;
    private ShellNavigationContext? _context;
    private static readonly HttpClient UpdateHttpClient = new() { Timeout = TimeSpan.FromSeconds(10) };
    private bool _checkingUpdate;
    private string? _updateUrl;
    private ServerSyncSettings? _syncSettings;
    private int _aboutTapCount;
    private DateTimeOffset _lastAboutTap;
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
        NotificationPreviewToggle.IsOn=(await services.Cache.GetSettingAsync("settings.notificationPreview"))!="false";
        TrayToggle.IsOn=(await services.Cache.GetSettingAsync("settings.tray"))=="true";
        var theme=await services.Cache.GetSettingAsync("settings.theme")??"system"; ThemePicker.SelectedIndex=theme=="light"?1:theme=="dark"?2:0;
        var language=await services.Cache.GetSettingAsync("settings.language")??"system"; LanguagePicker.SelectedIndex=language=="en"?1:language=="zh-Hans"?2:language=="zh-Hant"?3:0;
        await services.Appearance.InitializeAsync();
        BubbleFollowSystemToggle.IsOn=services.Appearance.BubbleFollowsSystem;
        BubbleColorPicker.Color=services.Appearance.BubbleColor;
        BubbleColorCard.Visibility=services.Appearance.BubbleFollowsSystem?Visibility.Collapsed:Visibility.Visible;
        TwemojiFlagsToggle.IsOn=services.Appearance.TwemojiFlagsEnabled;
        UpdateBackgroundStatus();
        DeveloperPanel.Visibility=(await services.Cache.GetSettingAsync("settings.developerMode"))=="true"?Visibility.Visible:Visibility.Collapsed;
        await LoadSmsStateAsync();
        _loading=false;services.Notifications.Enabled=NotificationToggle.IsOn;services.Notifications.ShowMessageText=NotificationPreviewToggle.IsOn;ApplyText();ApplySection(_context?.Section??"general");
        await RestoreVcfSummaryAsync();
        UpdateHiddenContactsStatus();
        await LoadTestContactStateAsync();
    }

    /// <summary>Old servers without the test-contact endpoints just hide the card.</summary>
    private async Task LoadTestContactStateAsync()
    {
        var api = AppServices.Current.Connection.Api;
        if (api is null) { TestingHeader.Visibility = Visibility.Collapsed; TestContactCard.Visibility = Visibility.Collapsed; return; }
        try
        {
            var enabled = await api.GetTestContactEnabledAsync();
            _loadingTestContact = true;
            TestContactToggle.IsOn = enabled;
            _loadingTestContact = false;
        }
        catch
        {
            TestingHeader.Visibility = Visibility.Collapsed;
            TestContactCard.Visibility = Visibility.Collapsed;
        }
    }

    private bool _loadingTestContact;

    private async Task LoadSmsStateAsync()
    {
        var api=AppServices.Current.Connection.Api;
        if(api is null){SmsToggle.IsEnabled=false;return;}
        try{_syncSettings=await api.GetSyncSettingsAsync();SmsToggle.IsOn=_syncSettings.AllowSmsSend;SmsToggle.IsEnabled=true;}
        catch{SmsToggle.IsEnabled=false;}
    }

    private async void SmsToggle_Toggled(object sender,RoutedEventArgs e)
    {
        if(_loading||_syncSettings is null)return;
        var api=AppServices.Current.Connection.Api;if(api is null)return;
        SmsToggle.IsEnabled=false;
        try{_syncSettings=await api.SetSyncSettingsAsync(_syncSettings with{AllowSmsSend=SmsToggle.IsOn});if(_context is not null)await _context.Host.RefreshChatListAsync();}
        catch(Exception exception){_loading=true;SmsToggle.IsOn=_syncSettings.AllowSmsSend;_loading=false;SmsDescription.Text=exception.Message;}
        finally{SmsToggle.IsEnabled=true;}
    }

    private async void TestContactToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (_loading || _loadingTestContact) return;
        var api = AppServices.Current.Connection.Api;
        if (api is null) return;
        try
        {
            await api.SetTestContactEnabledAsync(TestContactToggle.IsOn);
            if (_context is not null) await _context.Host.RefreshChatListAsync();
        }
        catch (Exception exception)
        {
            TestContactHint.Text = exception.Message;
        }
    }

    private async void ExportBackupButton_Click(object sender, RoutedEventArgs e)
    {
        var l = AppServices.Current.Localization;
        var picker = new Windows.Storage.Pickers.FileSavePicker { SuggestedFileName = $"micaGO-{DateTime.Now:yyyyMMdd}" };
        picker.FileTypeChoices.Add("micaGO backup", [".micagobak"]);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow));
        var file = await picker.PickSaveFileAsync();
        if (file is null) return;
        try
        {
            var version = typeof(SettingsPage).Assembly.GetName().Version?.ToString(3) ?? "?";
            var summary = await AppServices.Current.Backup.ExportAsync(file.Path, version);
            BackupStatus.Text = string.Format(l["backupSaved"], summary.SettingCount);
        }
        catch (Exception exception)
        {
            BackupStatus.Text = string.Format(l["backupFailed"], exception.Message);
        }
    }

    private async void ImportBackupButton_Click(object sender, RoutedEventArgs e)
    {
        var l = AppServices.Current.Localization;
        var picker = new Windows.Storage.Pickers.FileOpenPicker();
        picker.FileTypeFilter.Add(".micagobak");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow));
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        try
        {
            var summary = await AppServices.Current.Backup.ImportAsync(file.Path);
            BackupStatus.Text = string.Format(l["backupRestored"], summary.SettingCount);
            // Re-apply restored preferences immediately.
            _loading = true;
            await LoadStateAfterRestoreAsync();
            _loading = false;
            ApplySettings();
            if (_context is not null) await _context.Host.RefreshAppearanceAsync();
        }
        catch (Exception exception)
        {
            BackupStatus.Text = string.Format(l["backupFailed"], exception.Message);
        }
    }

    private async Task LoadStateAfterRestoreAsync()
    {
        var services = AppServices.Current;
        NotificationToggle.IsOn = (await services.Cache.GetSettingAsync("settings.notifications")) != "false";
        NotificationPreviewToggle.IsOn = (await services.Cache.GetSettingAsync("settings.notificationPreview")) != "false";
        TrayToggle.IsOn = (await services.Cache.GetSettingAsync("settings.tray")) == "true";
        await App.SetTrayEnabledAsync(TrayToggle.IsOn);
        var theme = await services.Cache.GetSettingAsync("settings.theme") ?? "system";
        ThemePicker.SelectedIndex = theme == "light" ? 1 : theme == "dark" ? 2 : 0;
        var language = await services.Cache.GetSettingAsync("settings.language") ?? "system";
        LanguagePicker.SelectedIndex = language == "en" ? 1 : language == "zh-Hans" ? 2 : language == "zh-Hant" ? 3 : 0;
        services.Notifications.ShowMessageText=NotificationPreviewToggle.IsOn;
        await LoadSmsStateAsync();
    }

    private const string VcfSummaryKey = "contacts.vcfSummary";

    /// <summary>The last import result is persisted so the Contacts page still
    /// shows it after an app restart (the contacts themselves already survive).</summary>
    private async Task RestoreVcfSummaryAsync()
    {
        if (!string.IsNullOrWhiteSpace(VcfImportStatus.Text)) return;
        var summary = await AppServices.Current.Cache.GetSettingAsync(VcfSummaryKey);
        var parts = (summary ?? string.Empty).Split('|');
        if (parts.Length >= 3)
            VcfImportStatus.Text = string.Format(AppServices.Current.Localization["vcfImported"], parts[0], parts[1], parts[2]);
    }
    private void ApplySettings(){var s=AppServices.Current;s.Notifications.Enabled=NotificationToggle.IsOn;s.Notifications.ShowMessageText=NotificationPreviewToggle.IsOn;NotificationPreviewToggle.IsEnabled=NotificationToggle.IsOn;var lang=LanguagePicker.SelectedIndex switch{1=>"en",2=>"zh-Hans",3=>"zh-Hant",_=>"system"};s.Localization.SetLanguage(lang);s.Notifications.HiddenBodyText=s.Localization["newMessage"];var root=App.MainWindow.Content as FrameworkElement;if(root is not null)root.RequestedTheme=ThemePicker.SelectedIndex switch{1=>ElementTheme.Light,2=>ElementTheme.Dark,_=>ElementTheme.Default};ApplyText();}
    private void ApplyText()
    {
        var l=AppServices.Current.Localization;
        ConnectionHeader.Text=l["connection"];BehaviorHeader.Text=l["general"];TrayLabel.Text=l["tray"];TrayDescription.Text=l["trayDescription"];LanguageLabel.Text=l["language"];SmsLabel.Text=l["allowSms"];SmsDescription.Text=l["allowSmsDescription"];
        AppearanceHeader.Text=l["appearance"];ThemeLabel.Text=l["theme"];EmojiHeader.Text=l["emoji"];TwemojiFlagsLabel.Text=l["twemojiFlags"];TwemojiFlagsDescription.Text=l["twemojiFlagsDescription"];ChatBackgroundLabel.Text=l["chatBackground"];ChooseBackgroundButton.Content=l["choose"];ClearBackgroundButton.Content=l["removeBackground"];BubbleColorLabel.Text=l["bubbleColor"];BubbleFollowSystemLabel.Text=l["followSystemAccent"];BubbleColorPickLabel.Text=l["customColor"];BubbleColorButton.Content=l["choose"];
        NotificationsHeader.Text=l["notifications"];NotificationLabel.Text=l["notify"];NotificationDescription.Text=l["notificationDescription"];NotificationPreviewLabel.Text=l["notificationPreview"];NotificationPreviewDescription.Text=l["notificationPreviewDescription"];NotificationInfo.Message=l["notificationHistorySilent"];
        ContactsHeader.Text=l["contacts"];ContactsHint.Text=l["contactsHint"];ImportVcfLabel.Text=l["importVcf"];ImportVcfButton.Content=l["chooseVcf"];ClearVcfButton.Content=l["clearContacts"];HiddenMessagesLabel.Text=l["hiddenMessages"];HiddenContactsLabel.Text=l["hiddenContacts"];StorageHeader.Text=l["cache"];CacheLabel.Text=l["cacheLabel"];ClearCacheHint.Text=l["clearCache"];ClearCacheButton.Content=l["clearCacheButton"];
        TestingHeader.Text=l["developer"];TestContactLabel.Text=l["testContact"];TestContactHint.Text=l["testContactHint"];BackupHeader.Text=l["backupRestore"];BackupLabel.Text=l["backupLabel"];ExportBackupButton.Content=l["exportBackup"];ImportBackupButton.Content=l["importBackup"];
        AboutHeader.Text=l["about"];AboutSubtitleText.Text=l["aboutSubtitle"];AboutVersionText.Text=string.Format(l["version"],typeof(SettingsPage).Assembly.GetName().Version?.ToString(3)??"?");AboutGitHubLabel.Text=l["viewOnGitHub"];AboutUpdateLabel.Text=l["checkUpdates"];if(!_checkingUpdate&&_updateUrl is null)AboutUpdateStatus.Text=l["updateCheckNow"];if(_updateUrl is null&&!_checkingUpdate)AboutUpdateButton.Content=l["updateCheckButton"];AboutOpenSourceLabel.Text=l["openSource"];AboutAttributionText.Text=l["twemojiAttribution"];AboutDisclaimerText.Text=l["twemojiDisclaimer"];
        UpdateBackgroundStatus();UpdateHiddenContactsStatus();UpdateHiddenMessagesStatus();
    }
    private async void NotificationToggle_Toggled(object sender,RoutedEventArgs e){if(_loading)return;await AppServices.Current.Cache.SetSettingAsync("settings.notifications",NotificationToggle.IsOn?"true":"false");ApplySettings();}
    private async void NotificationPreviewToggle_Toggled(object sender,RoutedEventArgs e){if(_loading)return;await AppServices.Current.Cache.SetSettingAsync("settings.notificationPreview",NotificationPreviewToggle.IsOn?"true":"false");ApplySettings();}
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
    private async void BubbleFollowSystemToggle_Toggled(object sender,RoutedEventArgs e){if(_loading)return;BubbleColorCard.Visibility=BubbleFollowSystemToggle.IsOn?Visibility.Collapsed:Visibility.Visible;await AppServices.Current.Appearance.SetBubbleFollowsSystemAsync(BubbleFollowSystemToggle.IsOn);if(_context is not null)await _context.Host.RefreshAppearanceAsync();}
    private async void BubbleColorPicker_ColorChanged(ColorPicker sender,ColorChangedEventArgs args){if(_loading||BubbleFollowSystemToggle.IsOn)return;await AppServices.Current.Appearance.SetBubbleColorAsync(args.NewColor);if(_context is not null)await _context.Host.RefreshAppearanceAsync();}
    private async void TwemojiFlagsToggle_Toggled(object sender,RoutedEventArgs e){if(_loading)return;await AppServices.Current.Appearance.SetTwemojiFlagsEnabledAsync(TwemojiFlagsToggle.IsOn);if(_context is not null)await _context.Host.RefreshAppearanceAsync();}
    private void UpdateBackgroundStatus(){if(ChatBackgroundStatus is null)return;var l=AppServices.Current.Localization;var custom=!string.IsNullOrWhiteSpace(AppServices.Current.Appearance.ChatBackgroundPath)&&File.Exists(AppServices.Current.Appearance.ChatBackgroundPath);ChatBackgroundStatus.Text=l[custom?"customBackground":"defaultMicaBackground"];ClearBackgroundButton.IsEnabled=custom;}
    private async void ImportVcfButton_Click(object sender,RoutedEventArgs e)
    {
        var picker=new Windows.Storage.Pickers.FileOpenPicker();picker.FileTypeFilter.Add(".vcf");
        WinRT.Interop.InitializeWithWindow.Initialize(picker,WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow));
        var files=await picker.PickMultipleFilesAsync();if(files.Count==0)return;
        ImportVcfButton.IsEnabled=false;VcfImportStatus.Text=AppServices.Current.Localization["importingVcf"];
        try{var contacts=0;var identities=0;var skipped=0;foreach(var file in files){var result=await AppServices.Current.VcfContacts.ImportAsync(file.Path);contacts+=result.ContactCount;identities+=result.IdentityCount;skipped+=result.SkippedCards;}if(_context is not null)await _context.Host.RefreshContactsAsync();VcfImportStatus.Text=string.Format(AppServices.Current.Localization["vcfImported"],contacts,identities,skipped);await AppServices.Current.Cache.SetSettingAsync(VcfSummaryKey,$"{contacts}|{identities}|{skipped}");}
        catch(Exception exception){VcfImportStatus.Text=string.Format(AppServices.Current.Localization["vcfImportFailed"],exception.Message);}
        finally{ImportVcfButton.IsEnabled=true;}
    }
    private async void ClearVcfButton_Click(object sender,RoutedEventArgs e)
    {
        var l=AppServices.Current.Localization;var dialog=new ContentDialog{XamlRoot=XamlRoot,Title=l["clearContactsTitle"],Content=l["clearContactsConfirm"],PrimaryButtonText=l["clearContacts"],CloseButtonText=l["cancel"],DefaultButton=ContentDialogButton.Close};
        if(await dialog.ShowAsync()!=ContentDialogResult.Primary)return;
        ImportVcfButton.IsEnabled=false;ClearVcfButton.IsEnabled=false;
        try{await AppServices.Current.VcfContacts.ClearAllAsync();await AppServices.Current.Cache.SetSettingAsync(VcfSummaryKey,string.Empty);if(_context is not null)await _context.Host.RefreshContactsAsync();VcfImportStatus.Text=l["contactsCleared"];}
        finally{ImportVcfButton.IsEnabled=true;ClearVcfButton.IsEnabled=true;}
    }
    private void UpdateHiddenContactsStatus(){if(HiddenContactsStatus is null)return;var count=_context?.Host.HiddenChatCount??0;HiddenContactsStatus.Text=string.Format(AppServices.Current.Localization["hiddenContactsCount"],count);}
    private void HiddenContactsButton_Click(object sender,RoutedEventArgs e)=>_context?.Host.OpenHiddenContacts();
    private void UpdateHiddenMessagesStatus(){if(HiddenMessagesStatus is not null)HiddenMessagesStatus.Text=string.Format(AppServices.Current.Localization["hiddenMessagesCount"],_context?.Host.HiddenMessageCount??0);}
    private void HiddenMessagesButton_Click(object sender,RoutedEventArgs e)=>_context?.Host.OpenHiddenMessages();
    private async void ClearCacheButton_Click(object sender,RoutedEventArgs e){var l=AppServices.Current.Localization;var dialog=new ContentDialog{XamlRoot=XamlRoot,Title=l["clearCacheTitle"],Content=l["clearCacheConfirm"],PrimaryButtonText=l["clearCacheButton"],CloseButtonText=l["cancel"],DefaultButton=ContentDialogButton.Close};if(await dialog.ShowAsync()!=ContentDialogResult.Primary)return;await AppServices.Current.Cache.ClearContentCacheAsync();await AppServices.Current.Media.ClearAsync();ClearCacheHint.Text=l["cacheCleared"];}

    private async void AboutIdentity_Tapped(object sender,Microsoft.UI.Xaml.Input.TappedRoutedEventArgs e)
    {
        var now=DateTimeOffset.UtcNow;if(now-_lastAboutTap>TimeSpan.FromSeconds(4))_aboutTapCount=0;_lastAboutTap=now;
        if(++_aboutTapCount<7)return;
        _aboutTapCount=0;DeveloperPanel.Visibility=Visibility.Visible;await AppServices.Current.Cache.SetSettingAsync("settings.developerMode","true");await LoadTestContactStateAsync();
    }
    /// <summary>
    /// C74: asks GitHub whether a newer release exists. When one does, the
    /// button turns into "Open release" and links to it — nothing is downloaded
    /// or installed automatically.
    /// </summary>
    private async void CheckForUpdates_Click(object sender, RoutedEventArgs e)
    {
        var l = AppServices.Current.Localization;
        if (_updateUrl is { } url)
        {
            try { await Windows.System.Launcher.LaunchUriAsync(new Uri(url)); } catch { }
            return;
        }
        if (_checkingUpdate) return;
        _checkingUpdate = true;
        AboutUpdateButton.IsEnabled = false;
        AboutUpdateStatus.Text = l["updateChecking"];
        try
        {
            var current = typeof(SettingsPage).Assembly.GetName().Version?.ToString(3) ?? "0.0.0";
            var result = await UpdateCheck.FetchAsync(UpdateHttpClient, current);
            switch (result.Status)
            {
                case UpdateCheckStatus.UpdateAvailable:
                    _updateUrl = result.ReleaseUrl;
                    AboutUpdateStatus.Text = string.Format(l["updateAvailable"], result.LatestVersion);
                    AboutUpdateButton.Content = l["updateOpen"];
                    break;
                case UpdateCheckStatus.UpToDate:
                    AboutUpdateStatus.Text = l["updateUpToDate"];
                    break;
                default:
                    AboutUpdateStatus.Text = l["updateUnknown"];
                    break;
            }
        }
        finally
        {
            _checkingUpdate = false;
            AboutUpdateButton.IsEnabled = true;
        }
    }

    private void ApplySection(string section){GeneralSection.Visibility=section=="general"?Visibility.Visible:Visibility.Collapsed;AppearanceSection.Visibility=section=="appearance"?Visibility.Visible:Visibility.Collapsed;NotificationSection.Visibility=section=="notifications"?Visibility.Visible:Visibility.Collapsed;DataSection.Visibility=section=="data"?Visibility.Visible:Visibility.Collapsed;AboutSection.Visibility=section=="about"?Visibility.Visible:Visibility.Collapsed;}
    private async void DisconnectButton_Click(object sender,RoutedEventArgs e){var d=new ContentDialog{XamlRoot=XamlRoot,Title="Disconnect this PC?",Content="The saved server route and token will be removed from Windows Credential Manager.",PrimaryButtonText="Disconnect",CloseButtonText="Cancel",DefaultButton=ContentDialogButton.Close};if(await d.ShowAsync()!=ContentDialogResult.Primary)return;await AppServices.Current.Connection.DisconnectAsync();_context?.Host.NavigateToConnection();}
}

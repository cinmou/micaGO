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
    public SettingsPage() { InitializeComponent(); Loaded += SettingsPage_Loaded; Unloaded += SettingsPage_Unloaded; }
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
        ConnectionSubtitle.Text=services.Localization["route"];services.Connection.RoutesChanged-=Connection_RoutesChanged;services.Connection.RoutesChanged+=Connection_RoutesChanged;BuildRouteRows();_=ProbeRoutesQuietlyAsync();
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
            await AppServices.Current.MessagePreferences.RegisterLocalRecordsAsync();
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
        ConnectionHeader.Text=l["connection"];ConnectionSubtitle.Text=l["route"];UnpairLabel.Text=l["unpair"];UnpairDescription.Text=l["unpairDescription"];DisconnectButton.Content=l["unpairConfirm"];BuildRouteRows();BehaviorHeader.Text=l["general"];TrayLabel.Text=l["tray"];TrayDescription.Text=l["trayDescription"];LanguageLabel.Text=l["language"];SmsLabel.Text=l["allowSms"];SmsDescription.Text=l["allowSmsDescription"];
        AppearanceHeader.Text=l["appearance"];ThemeLabel.Text=l["theme"];LocalizePickers(l);EmojiHeader.Text=l["emoji"];TwemojiFlagsLabel.Text=l["twemojiFlags"];TwemojiFlagsDescription.Text=l["twemojiFlagsDescription"];ChatBackgroundLabel.Text=l["chatBackground"];ChooseBackgroundButton.Content=l["choose"];ClearBackgroundButton.Content=l["removeBackground"];BubbleColorLabel.Text=l["bubbleColor"];BubbleFollowSystemLabel.Text=l["followSystemAccent"];BubbleColorPickLabel.Text=l["presetColors"];BubbleColorButtonText.Text=l["customColor"];BuildBubbleSwatches();
        NotificationsHeader.Text=l["notifications"];NotificationLabel.Text=l["notify"];NotificationDescription.Text=l["notificationDescription"];NotificationPreviewLabel.Text=l["notificationPreview"];NotificationPreviewDescription.Text=l["notificationPreviewDescription"];
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
    // W-UI8: the ring picker fires on every drag step, so it only previews; the
    // colour is saved once when the flyout closes (it used to rewrite the setting
    // and refresh every bubble per step).
    private void BubbleColorPicker_ColorChanged(ColorPicker sender,ColorChangedEventArgs args){if(_loading)return;BubbleColorPreview.Background=new Microsoft.UI.Xaml.Media.SolidColorBrush(args.NewColor);}
    private async void BubbleColorFlyout_Closed(object sender,object e){if(_loading||BubbleFollowSystemToggle.IsOn)return;var color=BubbleColorPicker.Color;if(SameRgb(color,AppServices.Current.Appearance.BubbleColor)){UpdateBubbleColorSelection();return;}await ApplyBubbleColorAsync(color);}
    private async Task ApplyBubbleColorAsync(Windows.UI.Color color){await AppServices.Current.Appearance.SetBubbleColorAsync(color);UpdateBubbleColorSelection();if(_context is not null)await _context.Host.RefreshAppearanceAsync();}
    private static bool SameRgb(Windows.UI.Color a,Windows.UI.Color b)=>a.R==b.R&&a.G==b.G&&a.B==b.B;
    private void BuildBubbleSwatches()
    {
        var l=AppServices.Current.Localization;
        BubbleColorSwatches.Children.Clear();
        foreach(var (key,color) in MicaGo.App.Services.AppearanceService.BubbleColorPresets)
        {
            // Ellipse inside a transparent button: a coloured Button background
            // would be replaced by the template's grey on hover.
            var dot=new Grid{Width=28,Height=28};
            dot.Children.Add(new Microsoft.UI.Xaml.Shapes.Ellipse{Fill=new Microsoft.UI.Xaml.Media.SolidColorBrush(color)});
            dot.Children.Add(new FontIcon{Glyph="\uE73E",FontSize=14,HorizontalAlignment=HorizontalAlignment.Center,VerticalAlignment=VerticalAlignment.Center,Visibility=Visibility.Collapsed,
                Foreground=new Microsoft.UI.Xaml.Media.SolidColorBrush(MicaGo.App.Services.AppearanceService.ShouldUseDarkText(color)?Microsoft.UI.Colors.Black:Microsoft.UI.Colors.White)});
            var swatch=new Button{Width=36,Height=36,Padding=new Thickness(0),CornerRadius=new CornerRadius(18),BorderThickness=new Thickness(0),
                Background=new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent),Tag=color,Content=dot};
            ToolTipService.SetToolTip(swatch,l["color."+key]);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(swatch,l["color."+key]);
            swatch.Click+=async(_,_)=>{if(_loading)return;BubbleColorPicker.Color=color;await ApplyBubbleColorAsync(color);};
            BubbleColorSwatches.Children.Add(swatch);
        }
        UpdateBubbleColorSelection();
    }
    private void UpdateBubbleColorSelection()
    {
        var current=AppServices.Current.Appearance.BubbleColor;
        foreach(var child in BubbleColorSwatches.Children)
        {
            if(child is Button{Tag:Windows.UI.Color color,Content:Grid{Children:var parts}}&&parts.Count>1)
                parts[1].Visibility=SameRgb(color,current)?Visibility.Visible:Visibility.Collapsed;
        }
        BubbleColorPreview.Background=new Microsoft.UI.Xaml.Media.SolidColorBrush(current);
    }
    private async void TwemojiFlagsToggle_Toggled(object sender,RoutedEventArgs e){if(_loading)return;await AppServices.Current.Appearance.SetTwemojiFlagsEnabledAsync(TwemojiFlagsToggle.IsOn);if(_context is not null)await _context.Host.RefreshAppearanceAsync();}
    // ComboBox shows a snapshot of the selected item, so re-select after renaming.
    // _loading keeps the selection handlers from saving or re-applying settings.
    private void LocalizePickers(LocalizationService l)
    {
        var wasLoading=_loading;_loading=true;
        var theme=ThemePicker.SelectedIndex;var language=LanguagePicker.SelectedIndex;
        ((ComboBoxItem)ThemePicker.Items[0]).Content=l["themeSystem"];((ComboBoxItem)ThemePicker.Items[1]).Content=l["themeLight"];((ComboBoxItem)ThemePicker.Items[2]).Content=l["themeDark"];
        ((ComboBoxItem)LanguagePicker.Items[0]).Content=l["themeSystem"];
        ThemePicker.SelectedIndex=-1;ThemePicker.SelectedIndex=theme;LanguagePicker.SelectedIndex=-1;LanguagePicker.SelectedIndex=language;
        _loading=wasLoading;
    }
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
    // W-UI9: Flutter's route card. The radio marks the route in use; only available
    // routes can be picked. Checking a route only greys its row — it never
    // switches or disconnects.
    private bool _buildingRoutes;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _routeInfoTimer;
    private void SettingsPage_Unloaded(object sender,RoutedEventArgs e){AppServices.Current.Connection.RoutesChanged-=Connection_RoutesChanged;_routeInfoTimer?.Stop();}
    private void Connection_RoutesChanged(object? sender,EventArgs e){if(!DispatcherQueue.HasThreadAccess){DispatcherQueue.TryEnqueue(BuildRouteRows);return;}BuildRouteRows();}
    private static async Task ProbeRoutesQuietlyAsync(){try{await AppServices.Current.Connection.ProbeRoutesAsync();}catch{}}
    private void BuildRouteRows()
    {
        if(RouteList is null)return;
        var connection=AppServices.Current.Connection;var l=AppServices.Current.Localization;
        var routes=connection.RouteOptions;var active=connection.ActiveEndpoint?.Endpoint.BaseUrl;var switching=connection.SwitchingRoute;
        var statuses=new Dictionary<string,RouteRowStatus>(StringComparer.OrdinalIgnoreCase);
        foreach(var route in routes)statuses[route.BaseUrl]=RouteSelection.RowStatus(route.BaseUrl,switching,active,connection.RealtimeLive,connection.IsProbing(route.BaseUrl),connection.ProbeFor(route.BaseUrl));
        var inUse=RouteSelection.InUse(statuses,switching,active);
        _buildingRoutes=true;
        try
        {
            RouteList.Children.Clear();
            foreach(var route in routes)
            {
                var status=statuses[route.BaseUrl];
                var latency=connection.ProbeFor(route.BaseUrl)?.Latency is { } value?$" · {value.TotalMilliseconds:0} ms":string.Empty;
                var (key,suffix,accent)=status switch
                {
                    RouteRowStatus.Switching=>("routeSwitching","",true),
                    RouteRowStatus.Connected=>("routeConnected",latency,true),
                    RouteRowStatus.Connecting=>("routeConnecting","",false),
                    RouteRowStatus.Checking=>("routeChecking","",false),
                    RouteRowStatus.Available=>("routeAvailable",latency,false),
                    _=>("routeUnavailable","",false),
                };
                var isInUse=string.Equals(route.BaseUrl,inUse,StringComparison.OrdinalIgnoreCase);
                var text=new StackPanel{Spacing=1};
                text.Children.Add(new TextBlock{Text=route.BaseUrl,TextTrimming=TextTrimming.CharacterEllipsis});
                var caption=new TextBlock{Text=l[key]+suffix,FontSize=12};
                // Unaccented captions inherit the radio's foreground, so disabled rows grey out.
                if(accent&&Application.Current.Resources.TryGetValue("AccentTextFillColorPrimaryBrush",out var brush)&&brush is Microsoft.UI.Xaml.Media.Brush accentBrush)caption.Foreground=accentBrush;
                text.Children.Add(caption);
                var radio=new RadioButton{GroupName="micago-routes",Content=text,Tag=route.BaseUrl,IsChecked=isInUse,IsEnabled=isInUse||status==RouteRowStatus.Available};
                radio.Checked+=RouteRadio_Checked;
                RouteList.Children.Add(radio);
            }
        }
        finally{_buildingRoutes=false;}
    }
    private async void RouteRadio_Checked(object sender,RoutedEventArgs e)
    {
        if(_buildingRoutes||_loading||sender is not RadioButton{Tag:string baseUrl})return;
        var result=await AppServices.Current.Connection.SwitchRouteAsync(baseUrl);
        BuildRouteRows();
        var key=result switch{RouteSwitchResult.Switched=>"routeSwitchedToast",RouteSwitchResult.FellBack=>"routeFellBackToast",RouteSwitchResult.Unreachable=>"routeSwitchFailedToast",_=>null};
        if(key is null)return;
        RouteInfoBar.Message=AppServices.Current.Localization[key];
        RouteInfoBar.Severity=result==RouteSwitchResult.Switched?InfoBarSeverity.Success:InfoBarSeverity.Warning;
        RouteInfoBar.IsOpen=true;
        if(_routeInfoTimer is null){_routeInfoTimer=DispatcherQueue.CreateTimer();_routeInfoTimer.Interval=TimeSpan.FromSeconds(4);_routeInfoTimer.IsRepeating=false;_routeInfoTimer.Tick+=(_,_)=>RouteInfoBar.IsOpen=false;}
        _routeInfoTimer.Stop();_routeInfoTimer.Start();
    }
    // W-UI9 (Flutter C76): unpairing wipes the saved server, the token and the local
    // message/media cache, so the action and its dialog say exactly that.
    private async void DisconnectButton_Click(object sender,RoutedEventArgs e)
    {
        var services=AppServices.Current;var l=services.Localization;
        var dialog=new ContentDialog{XamlRoot=XamlRoot,Title=l["unpairTitle"],Content=new TextBlock{Text=l["unpairBody"],TextWrapping=TextWrapping.Wrap},PrimaryButtonText=l["unpairConfirm"],CloseButtonText=l["cancel"],DefaultButton=ContentDialogButton.Close};
        if(await dialog.ShowAsync()!=ContentDialogResult.Primary)return;
        await services.Connection.DisconnectAsync();
        try{await services.Cache.ClearContentCacheAsync();await services.Media.ClearAsync();}catch{}
        _context?.Host.NavigateToConnection();
    }
}

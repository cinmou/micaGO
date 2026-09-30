using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using MicaGo.App.Services;
using MicaGo.Core.Models;

namespace MicaGo.App.Views;

public sealed record HiddenMessageRow(string Id,string Title,string Preview,string Time);

public sealed partial class HiddenMessagesPage:Page
{
    private ShellNavigationContext? _context;private bool _selectMode;private bool _busy;
    public HiddenMessagesPage()=>InitializeComponent();
    protected override async void OnNavigatedTo(NavigationEventArgs e){base.OnNavigatedTo(e);_context=e.Parameter as ShellNavigationContext;AppServices.Current.MessagePreferences.Changed+=PreferencesChanged;ApplyText();await ReloadAsync();}
    protected override void OnNavigatedFrom(NavigationEventArgs e) {
        AppServices.Current.MessagePreferences.Changed-=PreferencesChanged;
        base.OnNavigatedFrom(e);
    }
    private void PreferencesChanged(object? sender,EventArgs args)=>DispatcherQueue.TryEnqueue(async () => await ReloadAsync());
    private async Task RunPreferenceAsync(Func<Task> action) {
        if(_busy)return; _busy=true;
        try {await action();}
        catch {RestoreInfoBar.Message=AppServices.Current.Localization["prefsConnect"];RestoreInfoBar.Severity=InfoBarSeverity.Error;RestoreInfoBar.IsOpen=true;}
        finally {_busy=false;await ReloadAsync();}
    }
    private async void ImportPreferences_Click(object sender,RoutedEventArgs e)=>await RunPreferenceAsync(()=>AppServices.Current.MessagePreferences.ImportLegacyAsync());
    private async void RetryPreferences_Click(object sender,RoutedEventArgs e)=>await RunPreferenceAsync(()=>AppServices.Current.MessagePreferences.SyncAsync());
    private async void ServerPreferences_Click(object sender,RoutedEventArgs e)=>await RunPreferenceAsync(()=>AppServices.Current.MessagePreferences.ResolveConflictsAsync(false));
    private async void MinePreferences_Click(object sender,RoutedEventArgs e)=>await RunPreferenceAsync(()=>AppServices.Current.MessagePreferences.ResolveConflictsAsync(true));

    private void ApplyText(){var l=AppServices.Current.Localization;TitleText.Text=l["hiddenMessages"];EmptyText.Text=l["noHiddenMessages"];ToolTipService.SetToolTip(SelectButton,l["select"]);ToolTipService.SetToolTip(SelectAllButton,l["selectAll"]);ToolTipService.SetToolTip(CancelSelectionButton,l["cancel"]);}
    private async Task ReloadAsync(){        var preferences=AppServices.Current.MessagePreferences;var l=AppServices.Current.Localization;
        PreferenceStatusText.Text=preferences.ErrorKey is { } errorKey?l[errorKey]:string.Empty;PreferenceStatusText.Visibility=preferences.ErrorKey is null?Visibility.Collapsed:Visibility.Visible;
        PreferencePanel.Visibility=preferences.ErrorKey is not null||preferences.LegacyCount>0||preferences.Pending||preferences.HasConflicts?Visibility.Visible:Visibility.Collapsed;
        ImportPreferencesButton.Content=string.Format(l["prefsImport"],preferences.LegacyCount);
        ImportPreferencesButton.Visibility=preferences.LegacyCount>0?Visibility.Visible:Visibility.Collapsed;
        RetryPreferencesButton.Content=l["prefsRetry"];RetryPreferencesButton.Visibility=preferences.Pending||preferences.ErrorKey is not null?Visibility.Visible:Visibility.Collapsed;
        ServerPreferencesButton.Content=l["prefsServer"];MinePreferencesButton.Content=l["prefsMine"];
        ServerPreferencesButton.Visibility=MinePreferencesButton.Visibility=preferences.HasConflicts?Visibility.Visible:Visibility.Collapsed;
IReadOnlyList<Message> messages=_context is null?Array.Empty<Message>():await _context.Host.GetHiddenMessagesAsync();var rows=messages.Select(message=>new HiddenMessageRow(message.ServerKey,message.IsOutgoing?AppServices.Current.Localization["you"]:message.SenderName??message.ChatId,MessageSemantics.PreviewText(message),message.SentAt)).ToArray();HiddenMessagesList.ItemsSource=rows;CountText.Text=string.Format(AppServices.Current.Localization["hiddenMessagesCount"],rows.Length);ListPanel.Visibility=rows.Length>0?Visibility.Visible:Visibility.Collapsed;EmptyState.Visibility=rows.Length==0?Visibility.Visible:Visibility.Collapsed;if(rows.Length==0)ExitSelectMode();}
    private void BackButton_Click(object sender,RoutedEventArgs e)=>_context?.Host.GoBackInDetail();private void SelectButton_Click(object sender,RoutedEventArgs e)=>EnterSelectMode();private void CancelSelectionButton_Click(object sender,RoutedEventArgs e)=>ExitSelectMode();
    private void SelectAllButton_Click(object sender,RoutedEventArgs e){if(HiddenMessagesList.SelectedItems.Count==HiddenMessagesList.Items.Count)HiddenMessagesList.SelectedItems.Clear();else{HiddenMessagesList.SelectedItems.Clear();foreach(var item in HiddenMessagesList.Items)HiddenMessagesList.SelectedItems.Add(item);}}
    private void List_ItemClick(object sender,ItemClickEventArgs e){if(_busy)return;if(!_selectMode)EnterSelectMode();HiddenMessagesList.SelectedItem=e.ClickedItem;}private void List_SelectionChanged(object sender,SelectionChangedEventArgs e)=>UpdateSelectionAction();
    private void EnterSelectMode(){_selectMode=true;HiddenMessagesList.SelectionMode=ListViewSelectionMode.Multiple;HiddenMessagesList.IsItemClickEnabled=false;SelectButton.Visibility=Visibility.Collapsed;SelectAllButton.Visibility=Visibility.Visible;CancelSelectionButton.Visibility=Visibility.Visible;RestoreSelectedButton.Visibility=Visibility.Visible;UpdateSelectionAction();}
    private void ExitSelectMode(){_selectMode=false;HiddenMessagesList.SelectedItems.Clear();HiddenMessagesList.SelectionMode=ListViewSelectionMode.None;HiddenMessagesList.IsItemClickEnabled=true;SelectButton.Visibility=HiddenMessagesList.Items.Count>0?Visibility.Visible:Visibility.Collapsed;SelectAllButton.Visibility=Visibility.Collapsed;CancelSelectionButton.Visibility=Visibility.Collapsed;RestoreSelectedButton.Visibility=Visibility.Collapsed;}
    private void UpdateSelectionAction(){var count=HiddenMessagesList.SelectedItems.Count;var label=AppServices.Current.Localization["restoreSelected"];RestoreSelectedButton.Content=count>0?$"{label} ({count})":label;RestoreSelectedButton.IsEnabled=count>0&&!_busy;}
    private async void RestoreOneButton_Click(object sender,RoutedEventArgs e){if(_busy||sender is not Button{Tag:string id})return;await RestoreAsync([id]);}private async void RestoreSelectedButton_Click(object sender,RoutedEventArgs e)=>await RestoreAsync(HiddenMessagesList.SelectedItems.OfType<HiddenMessageRow>().Select(row=>row.Id).ToArray());
    private async Task RestoreAsync(IReadOnlyList<string> ids){if(_busy||ids.Count==0||_context is null)return;_busy=true;UpdateSelectionAction();try { var restored=await _context.Host.RestoreHiddenMessagesAsync(ids);ExitSelectMode();RestoreInfoBar.Severity=InfoBarSeverity.Success;RestoreInfoBar.Message=string.Format(AppServices.Current.Localization["releasedMessages"],restored);RestoreInfoBar.IsOpen=true; }
        catch { RestoreInfoBar.Severity=InfoBarSeverity.Error;RestoreInfoBar.Message=AppServices.Current.Localization["prefsConnect"];RestoreInfoBar.IsOpen=true; }
        finally { _busy=false;await ReloadAsync();UpdateSelectionAction(); }}
}

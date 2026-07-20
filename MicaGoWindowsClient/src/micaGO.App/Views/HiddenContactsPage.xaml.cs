using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using MicaGo.App.Services;
using MicaGo.Core.Models;

namespace MicaGo.App.Views;

public sealed partial class HiddenContactsPage : Page
{
    private ShellNavigationContext? _context;
    private bool _selectMode;
    private bool _busy;

    public HiddenContactsPage()=>InitializeComponent();

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);_context=e.Parameter as ShellNavigationContext;ApplyText();Reload();
    }

    private void ApplyText()
    {
        var l=AppServices.Current.Localization;TitleText.Text=l["hiddenContacts"];EmptyText.Text=l["noHiddenContacts"];
        ToolTipService.SetToolTip(SelectButton,l["select"]);ToolTipService.SetToolTip(SelectAllButton,l["selectAll"]);ToolTipService.SetToolTip(CancelSelectionButton,l["cancel"]);
    }

    private void Reload()
    {
        var rows=_context?.Host.HiddenChats??[];HiddenContactsList.ItemsSource=rows;
        CountText.Text=string.Format(AppServices.Current.Localization["hiddenContactsCount"],rows.Count);
        ListPanel.Visibility=rows.Count>0?Visibility.Visible:Visibility.Collapsed;EmptyState.Visibility=rows.Count==0?Visibility.Visible:Visibility.Collapsed;
        if(rows.Count==0)ExitSelectMode();
    }

    private void BackButton_Click(object sender,RoutedEventArgs e)=>_context?.Host.GoBackInDetail();
    private void SelectButton_Click(object sender,RoutedEventArgs e)=>EnterSelectMode();
    private void CancelSelectionButton_Click(object sender,RoutedEventArgs e)=>ExitSelectMode();
    private void SelectAllButton_Click(object sender,RoutedEventArgs e)
    {
        if(HiddenContactsList.SelectedItems.Count==HiddenContactsList.Items.Count)HiddenContactsList.SelectedItems.Clear();
        else{HiddenContactsList.SelectedItems.Clear();foreach(var item in HiddenContactsList.Items)HiddenContactsList.SelectedItems.Add(item);}
    }
    private void HiddenContactsList_ItemClick(object sender,ItemClickEventArgs e)
    {
        if(_busy)return;if(!_selectMode)EnterSelectMode();HiddenContactsList.SelectedItem=e.ClickedItem;
    }
    private void HiddenContactsList_SelectionChanged(object sender,SelectionChangedEventArgs e)=>UpdateSelectionAction();
    private void HiddenContactsList_ContainerContentChanging(ListViewBase sender,ContainerContentChangingEventArgs args)
    {
        if(args.InRecycleQueue)return;
        if(FindNamed<Button>(args.ItemContainer,"RestoreOneButton") is{} button)button.Visibility=_selectMode?Visibility.Collapsed:Visibility.Visible;
    }

    private void EnterSelectMode()
    {
        _selectMode=true;HiddenContactsList.SelectionMode=ListViewSelectionMode.Multiple;HiddenContactsList.IsItemClickEnabled=false;
        SelectButton.Visibility=Visibility.Collapsed;SelectAllButton.Visibility=Visibility.Visible;CancelSelectionButton.Visibility=Visibility.Visible;RestoreSelectedButton.Visibility=Visibility.Visible;
        SetRestoreButtonsVisibility(Visibility.Collapsed);UpdateSelectionAction();
    }
    private void ExitSelectMode()
    {
        _selectMode=false;HiddenContactsList.SelectedItems.Clear();HiddenContactsList.SelectionMode=ListViewSelectionMode.None;HiddenContactsList.IsItemClickEnabled=true;
        SelectButton.Visibility=HiddenContactsList.Items.Count>0?Visibility.Visible:Visibility.Collapsed;SelectAllButton.Visibility=Visibility.Collapsed;CancelSelectionButton.Visibility=Visibility.Collapsed;RestoreSelectedButton.Visibility=Visibility.Collapsed;
        SetRestoreButtonsVisibility(Visibility.Visible);
    }
    private void UpdateSelectionAction()
    {
        var count=HiddenContactsList.SelectedItems.Count;var label=AppServices.Current.Localization["restoreSelected"];
        RestoreSelectedButton.Content=count>0?$"{label} ({count})":label;RestoreSelectedButton.IsEnabled=count>0&&!_busy;
    }
    private async void RestoreOneButton_Click(object sender,RoutedEventArgs e)
    {
        if(_busy||sender is not Button{Tag:string id})return;await RestoreAsync([id]);
    }
    private async void RestoreSelectedButton_Click(object sender,RoutedEventArgs e)
    {
        await RestoreAsync(HiddenContactsList.SelectedItems.OfType<ChatSummary>().Select(chat=>chat.Id).ToArray());
    }
    private async Task RestoreAsync(IReadOnlyList<string> ids)
    {
        if(_busy||ids.Count==0||_context is null)return;_busy=true;UpdateSelectionAction();
        var restored=await _context.Host.RestoreHiddenChatsAsync(ids);_busy=false;ExitSelectMode();Reload();
        RestoreInfoBar.Message=string.Format(AppServices.Current.Localization["releasedContacts"],restored);RestoreInfoBar.IsOpen=true;
    }
    private void SetRestoreButtonsVisibility(Visibility visibility)
    {
        for(var i=0;i<HiddenContactsList.Items.Count;i++)if(HiddenContactsList.ContainerFromIndex(i) is DependencyObject container&&FindNamed<Button>(container,"RestoreOneButton") is{} button)button.Visibility=visibility;
    }
    private static T? FindNamed<T>(DependencyObject root,string name)where T:FrameworkElement
    {
        if(root is T match&&match.Name==name)return match;
        for(var i=0;i<VisualTreeHelper.GetChildrenCount(root);i++)if(FindNamed<T>(VisualTreeHelper.GetChild(root,i),name) is{} nested)return nested;
        return null;
    }
}

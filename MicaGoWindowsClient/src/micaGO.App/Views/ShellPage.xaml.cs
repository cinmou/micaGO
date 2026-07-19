using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Navigation;
using MicaGo.App.Services;
using MicaGo.App.ViewModels;
using MicaGo.Core.Models;
using Windows.System;

namespace MicaGo.App.Views;

public sealed partial class ShellPage : Page
{
    private ShellViewModel? _viewModel;
    private readonly DispatcherTimer _timestampTimer=new(){Interval=TimeSpan.FromMinutes(1)};

    public ShellPage()
    {
        InitializeComponent();
        NavigationCacheMode=Microsoft.UI.Xaml.Navigation.NavigationCacheMode.Required;
        Loaded += ShellPage_Loaded;
        _timestampTimer.Tick+=(_,_)=>_viewModel?.RefreshChatTimestamps();
    }

    private async void ShellPage_Loaded(object sender, RoutedEventArgs e)
    {
        if(_viewModel is not null)return;
        await AppServices.Current.Cache.InitializeAsync();
        var language = await AppServices.Current.Cache.GetSettingAsync("settings.language");
        if (!string.IsNullOrWhiteSpace(language)) AppServices.Current.Localization.SetLanguage(language);
        ApplyLocalizedText();
        var api = AppServices.Current.Connection.Api;
        if (api is null) { Frame.Navigate(typeof(ConnectionPage)); return; }
        _viewModel = new ShellViewModel(DispatcherQueue, api, AppServices.Current);
        _viewModel.StateChanged += ViewModel_StateChanged;
        ChatList.ItemsSource = _viewModel.Chats;
        MessageList.ItemsSource = _viewModel.Messages;
        ConnectionStatusText.Text = $"Connected · {api.BaseUrl}";
        _timestampTimer.Start();
        try
        {
            await _viewModel.InitializeAsync();
            if (_viewModel.Chats.Count > 0) { ChatList.SelectedIndex = 0; await SelectChatAsync(_viewModel.Chats[0]); }
        }
        catch (Exception exception) { ConnectionStatusText.Text = $"Could not initialize: {exception.Message}"; }
    }

    private void ApplyLocalizedText()
    {
        var l=AppServices.Current.Localization;
        SearchBox.PlaceholderText=l["search"]; Composer.PlaceholderText=l["message"];
        ThreadTitle.Text=l["selectConversation"]; ThreadSubtitle.Text=l["localOnly"]; EmptyStateText.Text=l["chooseConversation"];
        SettingsSidebarTitle.Text=l["settings"]; GeneralSettingsLabel.Text=l["appearance"];
        ContactSettingsLabel.Text=l["contacts"]; StorageSettingsLabel.Text=l["cache"];
        ToolTipService.SetToolTip(AttachButton,l["attach"]); ToolTipService.SetToolTip(SendButton,l["send"]);
    }

    private void ViewModel_StateChanged(object? sender, EventArgs e)
    {
        if (_viewModel is null) return;
        ConnectionStatusText.Text = $"{_viewModel.SyncStatus} · {AppServices.Current.Connection.Api?.BaseUrl}";
        LoadOlderButton.Visibility=_viewModel.HasMoreMessages?Visibility.Visible:Visibility.Collapsed;LoadOlderButton.IsEnabled=!_viewModel.IsLoadingOlder;
    }
    private async void LoadOlderButton_Click(object sender,RoutedEventArgs e){if(_viewModel is null)return;var anchor=_viewModel.Messages.FirstOrDefault();await _viewModel.LoadOlderMessagesAsync();if(anchor is not null)MessageList.ScrollIntoView(anchor);}

    private async void ChatList_ItemClick(object sender, ItemClickEventArgs e) { if (e.ClickedItem is ChatSummary chat) await SelectChatAsync(chat); }

    private async Task SelectChatAsync(ChatSummary chat)
    {
        if (_viewModel is null) return;
        ShowConversationPane();
        ThreadInitials.Text = chat.Initials; ThreadTitle.Text = chat.Title;
        ThreadSubtitle.Text = chat.IsMuted ? $"{chat.ServiceLabel} · Notifications muted" : chat.ServiceLabel;
        await _viewModel.SelectChatAsync(chat);
        EmptyState.Visibility = Visibility.Collapsed;
        Composer.IsEnabled = chat.CanSendText;
        Composer.PlaceholderText = chat.CanSendText ? AppServices.Current.Localization["message"] : $"{chat.ServiceLabel} · —";
        SendButton.IsEnabled = !string.IsNullOrWhiteSpace(Composer.Text);
        ScrollToLastMessage();
    }

    private void SearchBox_TextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason != AutoSuggestionBoxTextChangeReason.UserInput || _viewModel is null) return;
        _viewModel.ApplyFilter(sender.Text);
        sender.ItemsSource = string.IsNullOrWhiteSpace(sender.Text) ? null : _viewModel.Chats.Take(8).ToArray();
    }

    private void SearchBox_SuggestionChosen(AutoSuggestBox sender, AutoSuggestBoxSuggestionChosenEventArgs args)
    {
        if (args.SelectedItem is ChatSummary chat) sender.Text = chat.Title;
    }

    private async void SearchBox_QuerySubmitted(AutoSuggestBox sender, AutoSuggestBoxQuerySubmittedEventArgs args)
    {
        if (_viewModel is null) return;
        var chat = args.ChosenSuggestion as ChatSummary
            ?? _viewModel.Chats.FirstOrDefault(item => item.Title.Contains(args.QueryText ?? string.Empty, StringComparison.CurrentCultureIgnoreCase));
        if (chat is null) return;
        ChatList.SelectedItem = chat;
        await SelectChatAsync(chat);
    }

    public void OpenSettings()
    {
        ChatSidebar.Visibility = Visibility.Collapsed;
        SettingsSidebar.Visibility = Visibility.Visible;
        ConversationPane.Visibility = Visibility.Collapsed;
        DetailFrame.Visibility = Visibility.Visible;
        SettingsNavigationList.SelectedIndex = 0;
    }

    private void SettingsBackButton_Click(object sender, RoutedEventArgs e) => ExitDetailMode();

    private void SettingsNavigationList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (SettingsSidebar.Visibility != Visibility.Visible || SettingsNavigationList.SelectedItem is not ListViewItem item) return;
        ShowSettingsSection(item.Tag?.ToString() ?? "general");
    }

    private void ShowSettingsSection(string section)
    {
        var context = new ShellNavigationContext(this, null, section);
        DetailFrame.Navigate(typeof(SettingsPage), context, new DrillInNavigationTransitionInfo());
    }

    private void ConversationInfoButton_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel?.SelectedChat is not { } chat) return;
        ConversationPane.Visibility = Visibility.Collapsed;
        DetailFrame.Visibility = Visibility.Visible;
        DetailFrame.Navigate(typeof(ConversationDetailsPage), new ShellNavigationContext(this, chat), new DrillInNavigationTransitionInfo());
    }

    private void ConversationBackButton_Click(object sender, RoutedEventArgs e) => ChatList.Focus(FocusState.Programmatic);

    private void ConversationMoreButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button button || _viewModel?.SelectedChat is null) return;
        var flyout = new MenuFlyout();
        var details = new MenuFlyoutItem { Text = AppServices.Current.Localization["details"], Icon = new SymbolIcon(Symbol.Contact) };
        details.Click += ConversationInfoButton_Click;
        flyout.Items.Add(details);
        flyout.ShowAt(button);
    }

    public void ExitDetailMode()
    {
        DetailFrame.BackStack.Clear();
        DetailFrame.Content = null;
        DetailFrame.Visibility = Visibility.Collapsed;
        SettingsSidebar.Visibility = Visibility.Collapsed;
        ChatSidebar.Visibility = Visibility.Visible;
        ConversationPane.Visibility = Visibility.Visible;
        SettingsNavigationList.SelectedItem = null;
    }

    public void NavigateToConnection()
    {
        ExitDetailMode();
        Frame.Navigate(typeof(ConnectionPage));
        Frame.BackStack.Clear();
    }

    public async Task RefreshContactsAsync()
    {
        if(_viewModel is null)return;await _viewModel.RefreshContactsAsync();ChatList.ItemsSource=_viewModel.Chats;
        if(_viewModel.SelectedChat is{} chat){ThreadInitials.Text=chat.Initials;ThreadTitle.Text=chat.Title;}
    }

    private void ShowConversationPane()
    {
        if (SettingsSidebar.Visibility == Visibility.Visible) return;
        DetailFrame.BackStack.Clear();
        DetailFrame.Content = null;
        DetailFrame.Visibility = Visibility.Collapsed;
        ConversationPane.Visibility = Visibility.Visible;
    }
    private async void SendButton_Click(object sender, RoutedEventArgs e) => await SendCurrentTextAsync();
    private async void Composer_KeyDown(object sender, KeyRoutedEventArgs e) { if (e.Key == VirtualKey.Enter) { e.Handled = true; await SendCurrentTextAsync(); } }
    private void Composer_TextChanged(object sender, TextChangedEventArgs e) => SendButton.IsEnabled = _viewModel?.SelectedChat is not null && !string.IsNullOrWhiteSpace(Composer.Text);

    private async Task SendCurrentTextAsync()
    {
        var text = Composer.Text.Trim(); if (_viewModel is null || string.IsNullOrEmpty(text)) return;
        Composer.Text = string.Empty; SendButton.IsEnabled = false; await _viewModel.SendTextAsync(text); ScrollToLastMessage();
    }

    private async void AttachButton_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel?.SelectedChat is null) return;
        var picker = new Windows.Storage.Pickers.FileOpenPicker();
        picker.FileTypeFilter.Add("*");
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);
        var files = await picker.PickMultipleFilesAsync();
        if (files.Count > 0) { await _viewModel.SendAttachmentsAsync(files.Select(file => file.Path)); ScrollToLastMessage(); }
    }

    private async void MessageList_RightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if (_viewModel is null || (e.OriginalSource as FrameworkElement)?.DataContext is not Message message) return;
        var menu = new MenuFlyout();
        if(message.IsPending && message.DeliveryState==MessageDeliveryState.Failed && message.Media.Count>0)
        {
            var retry=new MenuFlyoutItem{Text="Retry"};retry.Click+=async(_,_)=>await _viewModel.RetryAttachmentAsync(message);menu.Items.Add(retry);
        }
        if(message.IsPending&&message.DeliveryState==MessageDeliveryState.Sending&&message.Media.Count>0){var cancel=new MenuFlyoutItem{Text="Cancel upload"};cancel.Click+=(_,_)=>_viewModel.CancelAttachmentUpload(message);menu.Items.Add(cancel);}
        if (message.IsOutgoing && !message.IsPending)
        {
            if(_viewModel.ActionCapabilities.CanEdit){var edit = new MenuFlyoutItem { Text = AppServices.Current.Localization["edit"] }; edit.Click += async (_, _) => { var box = new TextBox { Text = message.Text, AcceptsReturn = true }; var dialog = new ContentDialog { Title = AppServices.Current.Localization["edit"], Content = box, PrimaryButtonText = AppServices.Current.Localization["edit"], CloseButtonText = "Cancel", XamlRoot = XamlRoot }; if (await dialog.ShowAsync() == ContentDialogResult.Primary) await _viewModel.EditAsync(message, box.Text); }; menu.Items.Add(edit);}
            if(_viewModel.ActionCapabilities.CanRetract){var retract = new MenuFlyoutItem { Text = AppServices.Current.Localization["unsend"] }; retract.Click += async (_, _) => await _viewModel.RetractAsync(message); menu.Items.Add(retract);}
        }
        if(message.IsPending||_viewModel.ActionCapabilities.CanDelete){var delete = new MenuFlyoutItem { Text = AppServices.Current.Localization["delete"] }; delete.Click += async (_, _) => await _viewModel.DeleteAsync(message); menu.Items.Add(delete);}
        menu.ShowAt(MessageList, e.GetPosition(MessageList));
    }

    private void ScrollToLastMessage() { if (_viewModel?.Messages.Count > 0) MessageList.ScrollIntoView(_viewModel.Messages[^1]); }
}

public sealed record ShellNavigationContext(ShellPage Host, ChatSummary? Chat = null, string Section = "general");

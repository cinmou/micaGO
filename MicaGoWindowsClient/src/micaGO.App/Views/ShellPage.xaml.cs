using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Navigation;
using MicaGo.App.Services;
using MicaGo.App.ViewModels;
using MicaGo.Core.Models;
using Windows.System;
using Windows.UI.Core;

namespace MicaGo.App.Views;

public sealed partial class ShellPage : Page
{
    private const string SidebarWidthRatioKey = "settings.sidebarWidthRatio";
    private const double MinimumDetailWidth = 380;
    private ShellViewModel? _viewModel;
    private readonly DispatcherTimer _timestampTimer=new(){Interval=TimeSpan.FromMinutes(1)};
    private double _sidebarWidthBeforeDrag;
    private double _sidebarPointerStartX;
    private bool _isSidebarDragging;
    private double? _preferredSidebarRatio;
    private ScrollViewer? _messageScroller;
    private bool _autoLoadingOlder;

    public ShellPage()
    {
        InitializeComponent();
        NavigationCacheMode=Microsoft.UI.Xaml.Navigation.NavigationCacheMode.Required;
        Loaded += ShellPage_Loaded;
        ShellRoot.SizeChanged += ShellRoot_SizeChanged;
        _timestampTimer.Tick+=(_,_)=>_viewModel?.RefreshChatTimestamps();
        Controls.MessageBubble.ReplyJumpRequested += OnReplyJumpRequested;
        Controls.MessageBubble.ScreenEffectRequested += OnScreenEffectRequested;
    }

    private async void ShellPage_Loaded(object sender, RoutedEventArgs e)
    {
        if(_viewModel is not null)return;
        await AppServices.Current.Cache.InitializeAsync();
        await AppServices.Current.Appearance.InitializeAsync();
        AppServices.Current.Appearance.AppearanceChanged += Appearance_AppearanceChanged;
        ApplyChatAppearance();
        RestoreSidebarWidth(await AppServices.Current.Cache.GetSettingAsync(SidebarWidthRatioKey));
        var language = await AppServices.Current.Cache.GetSettingAsync("settings.language");
        if (!string.IsNullOrWhiteSpace(language)) AppServices.Current.Localization.SetLanguage(language);
        ApplyLocalizedText();
        var api = AppServices.Current.Connection.Api;
        if (api is null) { App.ShowConnectionWindow(); return; }
        _viewModel = new ShellViewModel(DispatcherQueue, api, AppServices.Current);
        _viewModel.StateChanged += ViewModel_StateChanged;
        ChatList.ItemsSource = _viewModel.Chats;
        MessageList.ItemsSource = _viewModel.Messages;
        ConnectionStatusText.Text = $"Connected · {api.BaseUrl}";
        _timestampTimer.Start();
        try
        {
            await _viewModel.InitializeAsync();
            UpdateTrayContacts();
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
        ToolTipService.SetToolTip(SidebarSettingsButton,l["settings"]);
        ToolTipService.SetToolTip(ThreadDetailsButton,l["details"]);
    }

    private void ViewModel_StateChanged(object? sender, EventArgs e)
    {
        if (_viewModel is null) return;
        ConnectionStatusText.Text = $"{_viewModel.SyncStatus} · {AppServices.Current.Connection.Api?.BaseUrl}";
        OlderMessagesProgress.IsActive=_viewModel.IsLoadingOlder;
        OlderMessagesProgress.Visibility=_viewModel.IsLoadingOlder?Visibility.Visible:Visibility.Collapsed;
        UpdateTrayContacts();
    }
    private void UpdateTrayContacts(){if(_viewModel is null)return;App.UpdateTrayContacts(_viewModel.Chats.Take(6).Select(chat=>new TrayContact(chat.Id,chat.Title)));}

    private void MessageList_Loaded(object sender,RoutedEventArgs e)
    {
        if(_messageScroller is not null)return;
        _messageScroller=FindDescendant<ScrollViewer>(MessageList);
        if(_messageScroller is not null)_messageScroller.ViewChanged+=MessageScroller_ViewChanged;
    }

    private async void MessageScroller_ViewChanged(object? sender,ScrollViewerViewChangedEventArgs e)
    {
        if(_messageScroller is null||_messageScroller.VerticalOffset>160)return;
        await LoadOlderAutomaticallyAsync();
    }

    private async Task LoadOlderAutomaticallyAsync()
    {
        if(_autoLoadingOlder||_viewModel is null||!_viewModel.HasMoreMessages||_viewModel.IsLoadingOlder)return;
        _autoLoadingOlder=true;
        try
        {
            var anchor=_viewModel.Messages.FirstOrDefault();
            var anchorKey=anchor?.PresentationKey;
            var oldY=anchor is not null&&MessageList.ContainerFromItem(anchor) is FrameworkElement oldContainer
                ? oldContainer.TransformToVisual(MessageList).TransformPoint(new Windows.Foundation.Point()).Y : double.NaN;
            await _viewModel.LoadOlderMessagesAsync();
            if(anchorKey is null)return;
            var restored=_viewModel.Messages.FirstOrDefault(item=>item.PresentationKey==anchorKey);
            if(restored is null)return;
            MessageList.UpdateLayout();
            if(!double.IsNaN(oldY)&&MessageList.ContainerFromItem(restored) is FrameworkElement newContainer&&_messageScroller is not null)
            {
                var newY=newContainer.TransformToVisual(MessageList).TransformPoint(new Windows.Foundation.Point()).Y;
                _messageScroller.ChangeView(null,_messageScroller.VerticalOffset+(newY-oldY),null,true);
            }
            else MessageList.ScrollIntoView(restored,ScrollIntoViewAlignment.Leading);
        }
        finally{_autoLoadingOlder=false;}
    }

    private static T? FindDescendant<T>(DependencyObject root) where T:DependencyObject
    {
        for(var i=0;i<VisualTreeHelper.GetChildrenCount(root);i++){var child=VisualTreeHelper.GetChild(root,i);if(child is T match)return match;var nested=FindDescendant<T>(child);if(nested is not null)return nested;}
        return null;
    }

    private async void ChatList_ItemClick(object sender, ItemClickEventArgs e) { if (e.ClickedItem is ChatSummary chat) await SelectChatAsync(chat); }

    private async Task SelectChatAsync(ChatSummary chat)
    {
        if (_viewModel is null) return;
        ShowConversationPane();
        Controls.MessageBubble.ResetTransientState();
        ThreadAvatar.DisplayName = chat.Title;
        ThreadAvatar.ProfilePicture = Ui.Image(chat.AvatarPath);
        ThreadTitle.Text = chat.Title;
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
        DetailFrame.Navigate(typeof(SettingsPage), context, ForwardTransition());
    }

    private void SidebarSettingsButton_Click(object sender, RoutedEventArgs e) => OpenSettings();

    private void ConversationMoreButton_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel?.SelectedChat is not { } chat) return;
        ConversationPane.Visibility = Visibility.Collapsed;
        DetailFrame.Visibility = Visibility.Visible;
        DetailFrame.Navigate(typeof(ConversationDetailsPage), new ShellNavigationContext(this, chat), ForwardTransition());
    }

    public async Task OpenChatAsync(string chatId)
    {
        if(_viewModel is null)return;
        var chat=_viewModel.Chats.FirstOrDefault(item=>item.Id==chatId||(item.RouteIds?.Contains(chatId)??false));
        if(chat is null)return;
        ChatList.SelectedItem=chat;
        await SelectChatAsync(chat);
    }

    public void ExitDetailMode()
    {
        ConversationPane.Visibility = Visibility.Visible;
        DetailFrame.BackStack.Clear();
        DetailFrame.Content = null;
        DetailFrame.Visibility = Visibility.Collapsed;
        SettingsSidebar.Visibility = Visibility.Collapsed;
        ChatSidebar.Visibility = Visibility.Visible;
        SettingsNavigationList.SelectedItem = null;
    }

    public void NavigateToConnection()
    {
        ExitDetailMode();
        App.ShowConnectionWindow();
    }

    /// <summary>Stops the realtime loop and timers when the chat window closes.</summary>
    public async Task ShutdownAsync()
    {
        _timestampTimer.Stop();
        AppServices.Current.Appearance.AppearanceChanged -= Appearance_AppearanceChanged;
        Controls.MessageBubble.ReplyJumpRequested -= OnReplyJumpRequested;
        Controls.MessageBubble.ScreenEffectRequested -= OnScreenEffectRequested;
        if(_messageScroller is not null){_messageScroller.ViewChanged-=MessageScroller_ViewChanged;_messageScroller=null;}
        if (_viewModel is { } viewModel)
        {
            _viewModel = null;
            viewModel.StateChanged -= ViewModel_StateChanged;
            await viewModel.DisposeAsync();
        }
    }

    /// <summary>Scrolls to (and briefly flashes) the message a reply points at.</summary>
    private async void OnReplyJumpRequested(object? sender, string target)
    {
        if (_viewModel is null) return;
        var row = _viewModel.Messages.FirstOrDefault(item =>
            !item.IsSeparator
            && (string.Equals(item.Id, target, StringComparison.OrdinalIgnoreCase)
                || string.Equals(ThreadPresentation.NormalizeTarget(item.Id), target, StringComparison.OrdinalIgnoreCase)));
        if (row is null) return;
        MessageList.ScrollIntoView(row);
        await Task.Delay(140);
        if (MessageList.ContainerFromItem(row) is UIElement container)
        {
            container.Opacity = 0.35;
            await Task.Delay(160);
            container.Opacity = 1;
            await Task.Delay(140);
            container.Opacity = 0.55;
            await Task.Delay(160);
            container.Opacity = 1;
        }
    }

    private void OnScreenEffectRequested(object? sender, string effectId) => PlayScreenEffect(effectId);

    /// <summary>
    /// Lightweight port of the Flutter screen send effects: an emoji particle
    /// shower over the conversation area (the full CustomPainter systems are
    /// not reproduced).
    /// </summary>
    private void PlayScreenEffect(string effectId)
    {
        var width = EffectCanvas.ActualWidth;
        var height = EffectCanvas.ActualHeight;
        if (width < 10 || height < 10) return;
        var rising = effectId.Contains("Heart", StringComparison.OrdinalIgnoreCase)
            || effectId.Contains("HappyBirthday", StringComparison.OrdinalIgnoreCase);
        var emoji = effectId switch
        {
            _ when effectId.Contains("Confetti", StringComparison.OrdinalIgnoreCase) => "🎉",
            _ when effectId.Contains("Heart", StringComparison.OrdinalIgnoreCase) => "❤️",
            _ when effectId.Contains("HappyBirthday", StringComparison.OrdinalIgnoreCase) => "🎈",
            _ when effectId.Contains("Fireworks", StringComparison.OrdinalIgnoreCase) => "🎆",
            _ when effectId.Contains("Lasers", StringComparison.OrdinalIgnoreCase) => "⚡",
            _ when effectId.Contains("Spotlight", StringComparison.OrdinalIgnoreCase) => "💡",
            _ when effectId.Contains("Echo", StringComparison.OrdinalIgnoreCase) => "💬",
            _ => "✨",
        };
        var random = new Random();
        var storyboard = new Microsoft.UI.Xaml.Media.Animation.Storyboard();
        for (var i = 0; i < 32; i++)
        {
            var particle = new TextBlock { Text = emoji, FontSize = random.Next(14, 30), Opacity = 0 };
            var transform = new Microsoft.UI.Xaml.Media.TranslateTransform();
            particle.RenderTransform = transform;
            Canvas.SetLeft(particle, random.NextDouble() * width);
            Canvas.SetTop(particle, rising ? height + 20 : -30);
            EffectCanvas.Children.Add(particle);
            var travel = (height + 60) * (rising ? -1 : 1);
            var duration = random.Next(1300, 2400);
            var begin = TimeSpan.FromMilliseconds(random.Next(0, 450));
            var fall = new Microsoft.UI.Xaml.Media.Animation.DoubleAnimation
            {
                From = 0,
                To = travel,
                BeginTime = begin,
                Duration = new Duration(TimeSpan.FromMilliseconds(duration)),
            };
            Microsoft.UI.Xaml.Media.Animation.Storyboard.SetTarget(fall, transform);
            Microsoft.UI.Xaml.Media.Animation.Storyboard.SetTargetProperty(fall, "Y");
            storyboard.Children.Add(fall);
            var fade = new Microsoft.UI.Xaml.Media.Animation.DoubleAnimationUsingKeyFrames { BeginTime = begin };
            fade.KeyFrames.Add(new Microsoft.UI.Xaml.Media.Animation.LinearDoubleKeyFrame { KeyTime = TimeSpan.Zero, Value = 0 });
            fade.KeyFrames.Add(new Microsoft.UI.Xaml.Media.Animation.LinearDoubleKeyFrame { KeyTime = TimeSpan.FromMilliseconds(180), Value = 1 });
            fade.KeyFrames.Add(new Microsoft.UI.Xaml.Media.Animation.LinearDoubleKeyFrame { KeyTime = TimeSpan.FromMilliseconds(Math.Max(200, duration - 280)), Value = 1 });
            fade.KeyFrames.Add(new Microsoft.UI.Xaml.Media.Animation.LinearDoubleKeyFrame { KeyTime = TimeSpan.FromMilliseconds(duration), Value = 0 });
            Microsoft.UI.Xaml.Media.Animation.Storyboard.SetTarget(fade, particle);
            Microsoft.UI.Xaml.Media.Animation.Storyboard.SetTargetProperty(fade, "Opacity");
            storyboard.Children.Add(fade);
        }
        storyboard.Completed += (_, _) => EffectCanvas.Children.Clear();
        storyboard.Begin();
    }

    public async Task RefreshContactsAsync()
    {
        if(_viewModel is null)return;await _viewModel.RefreshContactsAsync();ChatList.ItemsSource=_viewModel.Chats;
        if(_viewModel.SelectedChat is{} chat){ThreadAvatar.DisplayName=chat.Title;ThreadAvatar.ProfilePicture=Ui.Image(chat.AvatarPath);ThreadTitle.Text=chat.Title;}
    }

    private void ShowConversationPane()
    {
        if (SettingsSidebar.Visibility == Visibility.Visible) return;
        DetailFrame.BackStack.Clear();
        DetailFrame.Content = null;
        DetailFrame.Visibility = Visibility.Collapsed;
        ConversationPane.Visibility = Visibility.Visible;
    }

    public async Task RefreshAppearanceAsync()
    {
        await AppServices.Current.Appearance.InitializeAsync();
        ApplyChatAppearance();
        Controls.MessageBubble.RefreshAppearance();
    }

    private void Appearance_AppearanceChanged(object? sender, EventArgs e)
    {
        if (!DispatcherQueue.HasThreadAccess)
        {
            DispatcherQueue.TryEnqueue(ApplyChatAppearance);
            return;
        }
        ApplyChatAppearance();
    }

    private void ApplyChatAppearance()
    {
        var path = AppServices.Current.Appearance.ChatBackgroundPath;
        if (!string.IsNullOrWhiteSpace(path) && File.Exists(path))
        {
            ChatBackgroundImage.Source = new BitmapImage(new Uri(path, UriKind.Absolute));
            ChatBackgroundImage.Visibility = Visibility.Visible;
        }
        else
        {
            ChatBackgroundImage.Source = null;
            ChatBackgroundImage.Visibility = Visibility.Collapsed;
        }
        Controls.MessageBubble.RefreshAppearance();
    }

    private static SlideNavigationTransitionInfo ForwardTransition() => new() { Effect = SlideNavigationTransitionEffect.FromRight };

    private void RestoreSidebarWidth(string? rawRatio)
    {
        if (double.TryParse(rawRatio, NumberStyles.Float, CultureInfo.InvariantCulture, out var ratio)
            && double.IsFinite(ratio)
            && ratio > 0)
        {
            _preferredSidebarRatio = ratio;
        }
        else
        {
            var defaultWidth = ShellRoot.ActualWidth >= 1500 ? 380 : ShellRoot.ActualWidth >= 1100 ? 340 : 300;
            _preferredSidebarRatio = defaultWidth / Math.Max(1, ShellRoot.ActualWidth);
        }

        ApplyPreferredSidebarWidth();
    }

    private void ShellRoot_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (_preferredSidebarRatio.HasValue) ApplyPreferredSidebarWidth();
    }

    private void ApplyPreferredSidebarWidth()
    {
        var desired = ShellRoot.ActualWidth * _preferredSidebarRatio.GetValueOrDefault();
        SidebarColumn.Width = new GridLength(ClampSidebarWidth(desired));
    }

    private double ClampSidebarWidth(double width)
    {
        var availableMaximum = Math.Max(SidebarColumn.MinWidth, ShellRoot.ActualWidth - MinimumDetailWidth);
        return Math.Clamp(width, SidebarColumn.MinWidth, Math.Min(SidebarColumn.MaxWidth, availableMaximum));
    }

    private void SidebarResizeGrip_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (sender is not UIElement grip) return;
        _isSidebarDragging = true;
        _sidebarWidthBeforeDrag = SidebarColumn.ActualWidth;
        _sidebarPointerStartX = e.GetCurrentPoint(ShellRoot).Position.X;
        grip.CapturePointer(e.Pointer);
        e.Handled = true;
    }

    private void SidebarResizeGrip_PointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_isSidebarDragging) return;
        var delta = e.GetCurrentPoint(ShellRoot).Position.X - _sidebarPointerStartX;
        var width = ClampSidebarWidth(_sidebarWidthBeforeDrag + delta);
        SidebarColumn.Width = new GridLength(width);
        _preferredSidebarRatio = width / Math.Max(1, ShellRoot.ActualWidth);
        e.Handled = true;
    }

    private async void SidebarResizeGrip_PointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (!_isSidebarDragging) return;
        _isSidebarDragging = false;
        if (sender is UIElement grip) grip.ReleasePointerCapture(e.Pointer);

        var ratio = SidebarColumn.ActualWidth / Math.Max(1, ShellRoot.ActualWidth);
        _preferredSidebarRatio = ratio;
        await AppServices.Current.Cache.SetSettingAsync(SidebarWidthRatioKey, ratio.ToString("R", CultureInfo.InvariantCulture));
        e.Handled = true;
    }

    private void SidebarResizeGrip_PointerCanceled(object sender, PointerRoutedEventArgs e) => CancelSidebarResize(e);

    private void SidebarResizeGrip_PointerCaptureLost(object sender, PointerRoutedEventArgs e) => CancelSidebarResize(e);

    private void CancelSidebarResize(PointerRoutedEventArgs e)
    {
        if (!_isSidebarDragging) return;
        _isSidebarDragging = false;
        SidebarColumn.Width = new GridLength(ClampSidebarWidth(_sidebarWidthBeforeDrag));
        _preferredSidebarRatio = SidebarColumn.ActualWidth / Math.Max(1, ShellRoot.ActualWidth);
        e.Handled = true;
    }
    private async void SendButton_Click(object sender, RoutedEventArgs e) => await SendCurrentTextAsync();
    private async void Composer_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        var shift=(InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift)&CoreVirtualKeyStates.Down)!=0;
        if(e.Key==VirtualKey.Enter&&!shift){e.Handled=true;await SendCurrentTextAsync();}
    }
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

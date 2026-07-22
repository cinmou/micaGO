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
    private bool _keepingMessageBottom;
    private readonly VoiceRecorderService _voiceRecorder = new();
    private readonly DispatcherTimer _voiceTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    private DateTimeOffset _voiceStartedAt;
    private bool _selectMode;

    public ShellPage()
    {
        InitializeComponent();
        NavigationCacheMode=Microsoft.UI.Xaml.Navigation.NavigationCacheMode.Required;
        Loaded += ShellPage_Loaded;
        ShellRoot.SizeChanged += ShellRoot_SizeChanged;
        _timestampTimer.Tick+=(_,_)=>_viewModel?.RefreshChatTimestamps();
        Controls.MessageBubble.ReplyJumpRequested += OnReplyJumpRequested;
        Controls.MessageBubble.ScreenEffectRequested += OnScreenEffectRequested;
        MessageList.SelectionChanged += MessageList_SelectionChanged;
        _voiceTimer.Tick += (_, _) =>
        {
            var elapsed = DateTimeOffset.Now - _voiceStartedAt;
            VoiceTimerText.Text = $"{(int)elapsed.TotalMinutes}:{elapsed.Seconds:00}";
        };
    }

    private async void ShellPage_Loaded(object sender, RoutedEventArgs e)
    {
        if(_viewModel is not null)return;
        await AppServices.Current.Cache.InitializeAsync();
        await AppServices.Current.RemoveLegacyGoogleContactsAsync();
        await AppServices.Current.Appearance.InitializeAsync();
        AppServices.Current.Appearance.AppearanceChanged += Appearance_AppearanceChanged;
        ApplyChatAppearance();
        RestoreSidebarWidth(await AppServices.Current.Cache.GetSettingAsync(SidebarWidthRatioKey));
        var language = await AppServices.Current.Cache.GetSettingAsync("settings.language");
        if (!string.IsNullOrWhiteSpace(language)) AppServices.Current.Localization.SetLanguage(language);
        ApplyLocalizedText();
        var api = AppServices.Current.Connection.Api;
        if (api is null)
        {
            // Launched straight into the chat window with a saved pairing —
            // finish the reconnect here instead of flashing the pairing window.
            ConnectionStatusText.Text = AppServices.Current.Localization["connChecking"];
            try
            {
                using var restoreTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
                await AppServices.Current.Connection.TryRestoreAsync(restoreTimeout.Token);
            }
            catch { }
            api = AppServices.Current.Connection.Api;
            if (api is null) { App.ShowConnectionWindow(); return; }
        }
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
        SettingsSidebarTitle.Text=l["settings"]; GeneralSettingsLabel.Text=l["general"]; AppearanceSettingsLabel.Text=l["appearance"];
        ContactSettingsLabel.Text=l["contacts"]; StorageSettingsLabel.Text=l["cache"]; AboutSettingsLabel.Text=l["about"];
        ToolTipService.SetToolTip(AttachButton,l["attach"]); ToolTipService.SetToolTip(SendButton,l["send"]);
        ToolTipService.SetToolTip(SidebarSettingsButton,l["settings"]);
        ToolTipService.SetToolTip(ThreadDetailsButton,l["details"]);
        ToolTipService.SetToolTip(VoiceButton,l["voiceMessage"]);
        ToolTipService.SetToolTip(JumpToBottomButton,l["jumpToBottom"]);
        VoiceCancelButton.Content=l["cancel"];
        SelectionForwardButton.Content=l["forward"];
        SelectionHideButton.Content=l["hide"];
    }

    private void ViewModel_StateChanged(object? sender, EventArgs e)
    {
        if (_viewModel is null) return;
        ConnectionStatusText.Text = $"{_viewModel.SyncStatus} · {AppServices.Current.Connection.Api?.BaseUrl}";
        OlderMessagesProgress.IsActive=_viewModel.IsLoadingOlder;
        OlderMessagesProgress.Visibility=_viewModel.IsLoadingOlder?Visibility.Visible:Visibility.Collapsed;
        UpdateThreadSubtitle();
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
        if (_messageScroller is not null)
        {
            var fromBottom = _messageScroller.ScrollableHeight - _messageScroller.VerticalOffset;
            JumpToBottomButton.Visibility = fromBottom > 420 ? Visibility.Visible : Visibility.Collapsed;
        }
        if(_keepingMessageBottom||_messageScroller is null||_messageScroller.VerticalOffset>160)return;
        await LoadOlderAutomaticallyAsync();
    }

    private void JumpToBottomButton_Click(object sender, RoutedEventArgs e)
    {
        if (_messageScroller is null) return;
        _messageScroller.ChangeView(null, _messageScroller.ScrollableHeight, null, false);
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

    private void ChatList_RightTapped(object sender,RightTappedRoutedEventArgs e)
    {
        if(_viewModel is null||(e.OriginalSource as FrameworkElement)?.DataContext is not ChatSummary chat)return;
        var menu=new MenuFlyout();
        var hide=new MenuFlyoutItem{Text=AppServices.Current.Localization["hide"],Icon=new FontIcon{Glyph="\uED1A"}};
        hide.Click+=async(_,_)=>
        {
            var wasSelected=_viewModel.SelectedChat is{} selected&&(selected.Id==chat.Id||chat.RouteIds?.Contains(selected.Id)==true);
            await _viewModel.HideChatAsync(chat);
            if(!wasSelected)return;
            ChatList.SelectedItem=null;
            if(_viewModel.Chats.FirstOrDefault() is{} next){ChatList.SelectedItem=next;await SelectChatAsync(next);return;}
            EmptyState.Visibility=Visibility.Visible;Composer.IsEnabled=false;VoiceButton.IsEnabled=false;SendButton.IsEnabled=false;
        };
        menu.Items.Add(hide);menu.ShowAt(ChatList,e.GetPosition(ChatList));e.Handled=true;
    }

    private async Task SelectChatAsync(ChatSummary chat)
    {
        if (_viewModel is null) return;
        ShowConversationPane();
        if (_viewModel.SelectedChat is { } current
            && _viewModel.Messages.Count > 0
            && (current.Id == chat.Id || current.RouteIds?.Contains(chat.Id) == true || chat.RouteIds?.Contains(current.Id) == true))
        {
            // Clicking the already-open row must not restart cache + REST loading;
            // doing so replaced the complete timeline twice and recycled every
            // visible bubble even though the conversation had not changed.
            return;
        }
        Controls.MessageBubble.ResetTransientState();
        ThreadAvatar.DisplayName = chat.Title;
        ThreadAvatar.ProfilePicture = Ui.Image(chat.AvatarPath);
        ThreadTitle.Text = chat.Title;
        ThreadSubtitle.Text = chat.Time;
        _keepingMessageBottom = true;
        try
        {
            await _viewModel.SelectChatAsync(chat);
            EmptyState.Visibility = Visibility.Collapsed;
            Composer.IsEnabled = chat.CanSendText;
            VoiceButton.IsEnabled = chat.CanSendText;
            Composer.PlaceholderText = chat.CanSendText ? AppServices.Current.Localization["message"] : "—";
            SendButton.IsEnabled = !string.IsNullOrWhiteSpace(Composer.Text);
            UpdateThreadSubtitle();
            await ScrollToLastMessageAsync();
        }
        finally { _keepingMessageBottom = false; }
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

    public void OpenHiddenContacts()
    {
        DetailFrame.Navigate(typeof(HiddenContactsPage),new ShellNavigationContext(this,null,"contacts"),ForwardTransition());
    }

    public void GoBackInDetail()
    {
        if(DetailFrame.CanGoBack)DetailFrame.GoBack(new SlideNavigationTransitionInfo{Effect=SlideNavigationTransitionEffect.FromLeft});
        else ShowSettingsSection("contacts");
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
        _voiceTimer.Stop();
        _voiceRecorder.Dispose();
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

    /// <summary>Re-fetches the chat list (used after toggling the offline test contact).</summary>
    public async Task RefreshChatListAsync()
    {
        if (_viewModel is not null) await _viewModel.ReloadChatsAsync();
    }

    public async Task RefreshContactsAsync()
    {
        if(_viewModel is null)return;await _viewModel.RefreshContactsAsync();
        if(_viewModel.SelectedChat is{} chat){ThreadAvatar.DisplayName=chat.Title;ThreadAvatar.ProfilePicture=Ui.Image(chat.AvatarPath);ThreadTitle.Text=chat.Title;}
    }

    public int HiddenChatCount=>_viewModel?.HiddenChatCount??0;
    public IReadOnlyList<ChatSummary> HiddenChats=>_viewModel?.HiddenChats??[];
    public async Task<int> RestoreHiddenChatsAsync(IEnumerable<string> chatIds)=>_viewModel is null?0:await _viewModel.RestoreHiddenChatsAsync(chatIds);

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
        Composer.Text = string.Empty; SendButton.IsEnabled = false;
        _keepingMessageBottom = true;
        try
        {
            // ItemsStackPanel.KeepLastItemInView owns the append scroll. A
            // manual scroll both before and after confirmation forced three
            // competing layout passes during rapid sends and exposed the
            // transparent message canvas between container realizations.
            await _viewModel.SendTextAsync(text);
            UpdateThreadSubtitle();
        }
        finally { _keepingMessageBottom = false; }
    }

    private async void AttachButton_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel?.SelectedChat is null) return;
        var picker = new Windows.Storage.Pickers.FileOpenPicker();
        picker.FileTypeFilter.Add("*");
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);
        var files = await picker.PickMultipleFilesAsync();
        if (files.Count == 0) return;
        _keepingMessageBottom = true;
        try
        {
            await _viewModel.SendAttachmentsAsync(files.Select(file => file.Path));
            UpdateThreadSubtitle();
        }
        finally { _keepingMessageBottom = false; }
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
        if(!message.IsSeparator&&!message.IsPresentationSystem)
        {
            if(!message.IsPending)
            {
                var hide=new MenuFlyoutItem{Text=AppServices.Current.Localization["hide"],Icon=new FontIcon{Glyph="\uED1A"}};
                hide.Click+=async(_,_)=>await _viewModel.HideMessagesAsync([message]);
                menu.Items.Add(hide);
            }
            var select=new MenuFlyoutItem{Text=AppServices.Current.Localization["select"],Icon=new FontIcon{Glyph="\uE762"}};
            select.Click+=(_,_)=>EnterSelectMode(message);
            menu.Items.Add(select);
        }
        menu.ShowAt(MessageList, e.GetPosition(MessageList));
    }

    // ----- voice messages -----

    private async void VoiceButton_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel?.SelectedChat is null || _voiceRecorder.IsRecording) return;
        try
        {
            await _voiceRecorder.StartAsync();
        }
        catch (Exception exception)
        {
            ConnectionStatusText.Text = $"Microphone unavailable: {exception.Message}";
            return;
        }
        _voiceStartedAt = DateTimeOffset.Now;
        VoiceTimerText.Text = "0:00";
        _voiceTimer.Start();
        ComposerBorder.Visibility = Visibility.Collapsed;
        VoiceBar.Visibility = Visibility.Visible;
    }

    private async void VoiceCancelButton_Click(object sender, RoutedEventArgs e)
    {
        _voiceTimer.Stop();
        await _voiceRecorder.CancelAsync();
        VoiceBar.Visibility = Visibility.Collapsed;
        ComposerBorder.Visibility = Visibility.Visible;
    }

    private async void VoiceSendButton_Click(object sender, RoutedEventArgs e)
    {
        _voiceTimer.Stop();
        var path = await _voiceRecorder.StopAsync();
        VoiceBar.Visibility = Visibility.Collapsed;
        ComposerBorder.Visibility = Visibility.Visible;
        if (path is null || _viewModel is null) return;
        _keepingMessageBottom = true;
        try
        {
            await _viewModel.SendAttachmentsAsync([path], isAudioMessage: true);
        }
        finally { _keepingMessageBottom = false; }
    }

    // ----- multi-select (forward / hide) -----

    private void EnterSelectMode(Message? initial)
    {
        if (_selectMode) return;
        _selectMode = true;
        MessageList.SelectionMode = ListViewSelectionMode.Multiple;
        ComposerBorder.Visibility = Visibility.Collapsed;
        VoiceBar.Visibility = Visibility.Collapsed;
        SelectionBar.Visibility = Visibility.Visible;
        if (initial is not null) MessageList.SelectedItems.Add(initial);
        UpdateSelectionBar();
    }

    private void ExitSelectMode()
    {
        if (!_selectMode) return;
        _selectMode = false;
        MessageList.SelectedItems.Clear();
        MessageList.SelectionMode = ListViewSelectionMode.None;
        SelectionBar.Visibility = Visibility.Collapsed;
        ComposerBorder.Visibility = Visibility.Visible;
    }

    private void MessageList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_selectMode) UpdateSelectionBar();
    }

    private IReadOnlyList<Message> SelectedMessages() =>
        MessageList.SelectedItems.OfType<Message>()
            .Where(message => !message.IsSeparator && !message.IsPresentationSystem)
            .OrderBy(message => message.DateCreated)
            .ToArray();

    private void UpdateSelectionBar()
    {
        var count = SelectedMessages().Count;
        var l = AppServices.Current.Localization;
        SelectionCountText.Text = string.Format(l["selectedCount"], count);
        SelectionForwardButton.Content = $"{l["forward"]} ({count})";
        SelectionHideButton.Content = $"{l["hide"]} ({count})";
        SelectionForwardButton.IsEnabled = count > 0;
        SelectionHideButton.IsEnabled = count > 0;
    }

    private void SelectionCancelButton_Click(object sender, RoutedEventArgs e) => ExitSelectMode();

    private async void SelectionForwardButton_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel is null) return;
        var selected = SelectedMessages();
        if (selected.Count == 0) return;
        var l = AppServices.Current.Localization;
        var picker = new ListView
        {
            ItemsSource = _viewModel.Chats,
            DisplayMemberPath = "Title",
            SelectionMode = ListViewSelectionMode.Single,
            MaxHeight = 380,
        };
        var dialog = new ContentDialog
        {
            Title = l["forwardTo"],
            Content = picker,
            PrimaryButtonText = l["forward"],
            CloseButtonText = l["cancel"],
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = XamlRoot,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || picker.SelectedItem is not ChatSummary target) return;
        ExitSelectMode();
        await _viewModel.ForwardMessagesAsync(target, selected);
    }

    private async void SelectionHideButton_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel is null) return;
        var selected = SelectedMessages();
        ExitSelectMode();
        if (selected.Count > 0) await _viewModel.HideMessagesAsync(selected);
    }

    private void UpdateThreadSubtitle()
    {
        if (_viewModel?.SelectedChat is not { } chat) return;
        var latestMessage = _viewModel.Messages.Where(message => !message.IsSeparator).Select(message => message.DateCreated).DefaultIfEmpty(0).Max();
        ThreadSubtitle.Text = _viewModel.FormatActivityTimestamp(Math.Max(chat.UpdatedAt, latestMessage));
    }

    private async Task ScrollToLastMessageAsync()
    {
        if (_viewModel?.Messages.Count is not > 0) return;
        await Task.Yield();
        MessageList.UpdateLayout();
        // One single scroll pass — the old ScrollIntoView + delay + second
        // ChangeView sequence produced a visible double-jump on every send.
        if (_messageScroller is { } scroller)
        {
            scroller.ChangeView(null, scroller.ScrollableHeight, null, true);
        }
        else
        {
            MessageList.ScrollIntoView(_viewModel.Messages[^1]);
        }
    }
}

public sealed record ShellNavigationContext(ShellPage Host, ChatSummary? Chat = null, string Section = "general");

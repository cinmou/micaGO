using System.Collections.Specialized;
using System.Globalization;
using System.Numerics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Navigation;
using MicaGo.App.Services;
using MicaGo.App.ViewModels;
using MicaGo.Core.Models;
using System.Runtime.InteropServices;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;
using Windows.System;
using Windows.UI.Core;
using Windows.UI.ViewManagement;
using Windows.UI.ViewManagement.Core;

namespace MicaGo.App.Views;

public sealed partial class ShellPage : Page
{
    private const uint InputKeyboard = 1;
    private const uint KeyEventKeyUp = 0x0002;
    private const ushort VirtualKeyLeftWindows = 0x5B;
    private const ushort VirtualKeyOemPeriod = 0xBE;
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
    private bool _shutDown;
    private readonly Controls.SidebarSelectionAnimation _chatSelectionAnimation;
    private readonly Controls.SidebarSelectionAnimation _settingsSelectionAnimation;
    private readonly DispatcherTimer _hideUndoTimer = new() { Interval = TimeSpan.FromSeconds(5) };
    private ChatSummary? _undoHiddenChat;
    private readonly List<(MessageRow Row,MessageEntranceKind Kind)> _pendingMessageEntrances=[];
    private bool _messageEntranceDrainScheduled;

    public ShellPage()
    {
        InitializeComponent();
        _chatSelectionAnimation = new(ChatList, ChatSelectionRegion, ChatSelectionIndicator);
        _settingsSelectionAnimation = new(SettingsNavigationList, SettingsSelectionRegion, SettingsSelectionIndicator);
        _hideUndoTimer.Tick += (_, _) => { _hideUndoTimer.Stop(); _undoHiddenChat = null; HideUndoFlyout.Hide(); };
        HideUndoFlyout.Closed += (_, _) => { _hideUndoTimer.Stop(); _undoHiddenChat = null; };
        NavigationCacheMode=Microsoft.UI.Xaml.Navigation.NavigationCacheMode.Required;
        Loaded += ShellPage_Loaded;
        ShellRoot.SizeChanged += ShellRoot_SizeChanged;
        var searchShortcut = new KeyboardAccelerator { Key = VirtualKey.F, Modifiers = VirtualKeyModifiers.Control };
        searchShortcut.Invoked += (_, args) =>
        {
            if (ChatSidebar.Visibility != Visibility.Visible) return;
            SearchBox.Focus(FocusState.Keyboard);
            args.Handled = true;
        };
        KeyboardAccelerators.Add(searchShortcut);
        AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(Shell_KeyDown), true);
        _timestampTimer.Tick+=(_,_)=>_viewModel?.RefreshChatTimestamps();
        Controls.MessageBubble.ReplyJumpRequested += OnReplyJumpRequested;
        Controls.MessageBubble.RetryRequested += OnRetryRequested;
        Controls.MessageBubble.ScreenEffectRequested += OnScreenEffectRequested;
        MessageList.SelectionChanged += MessageList_SelectionChanged;
        _voiceTimer.Tick += (_, _) =>
        {
            var elapsed = DateTimeOffset.Now - _voiceStartedAt;
            VoiceTimerText.Text = $"{(int)elapsed.TotalMinutes}:{elapsed.Seconds:00}";
        };
    }

    public async Task RefreshConnectionStatusVisibilityAsync()
    {
        var visible=await AppServices.Current.Cache.GetSettingAsync("settings.showConnectionStatus")!="false";
        ApplyConnectionStatusVisibility(visible);
    }
    private void ApplyConnectionStatusVisibility(bool visible)
    {
        ConnectionStatusPanel.Visibility=visible?Visibility.Visible:Visibility.Collapsed;
        ConnectionStatusRow.Height=new GridLength(visible?38:0);
    }

    private async void ShellPage_Loaded(object sender, RoutedEventArgs e)
    {
        await RefreshConnectionStatusVisibilityAsync();
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
        _viewModel.RealtimeChanged += ViewModel_RealtimeChanged;
        _viewModel.Chats.Mutated += ChatRows_Mutated;
        _viewModel.Messages.CollectionChanged += Messages_CollectionChanged;
        ChatList.ItemsSource = _viewModel.Chats;
        MessageList.ItemsSource = _viewModel.Messages;
        ConnectionStatusText.Text = $"{AppServices.Current.Localization["statusConnected"]} · {api.BaseUrl}";
        _timestampTimer.Start();
        try
        {
            await _viewModel.InitializeAsync();
            UpdateTrayContacts();
            if (_viewModel.Chats.Count > 0) { ChatList.SelectedIndex = 0; await SelectChatAsync(_viewModel.Chats[0]); }
        }
        catch (Exception exception) { ConnectionStatusText.Text = string.Format(AppServices.Current.Localization["initFailed"], exception.Message); }
    }

    private void ApplyLocalizedText()
    {
        var l=AppServices.Current.Localization;
        foreach (var (element, key) in new (DependencyObject, string)[] {
            (SearchBox, "search"), (Composer, "message"), (MessageList, "conversation"),
            (AttachButton, "attach"), (EmojiButton, "emoji"), (SendButton, "send"),
            (VoiceSendButton, "send"), (RecordVoiceItem, "recordVoice"),
            (ThreadDetailsButton, "details"), (ThreadIdentityButton, "details"), (JumpToBottomButton, "jumpToBottom"),
            (SelectionCancelButton, "cancel"), (SidebarSettingsButton, "settings") })
        {
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(element, l[key]);
        }

        SearchBox.PlaceholderText=l["search"]; Composer.PlaceholderText=l["message"];
        ThreadTitle.Text=l["selectConversation"]; ThreadSubtitle.Text=string.Empty; EmptyStateText.Text=l["chooseConversation"];
        SettingsSidebarTitle.Text=l["settings"]; GeneralSettingsLabel.Text=l["general"]; AppearanceSettingsLabel.Text=l["appearance"];
        ContactSettingsLabel.Text=l["notifications"]; StorageSettingsLabel.Text=l["data"]; AboutSettingsLabel.Text=l["about"];
        ToolTipService.SetToolTip(AttachButton,l["attach"]); ToolTipService.SetToolTip(SendButton,l["send"]);
        ToolTipService.SetToolTip(EmojiButton,l["emoji"]);
        ToolTipService.SetToolTip(SidebarSettingsButton,l["settings"]);
        ToolTipService.SetToolTip(ThreadDetailsButton,l["details"]);
        ToolTipService.SetToolTip(ThreadIdentityButton,l["details"]);
        AttachFilesItem.Text=l["attachFiles"];
        RecordVoiceItem.Text=l["recordVoice"];
        ToolTipService.SetToolTip(JumpToBottomButton,l["jumpToBottom"]);
        VoiceCancelButton.Content=l["cancel"];
        ToolTipService.SetToolTip(SettingsBackButton,l["back"]);
        SelectionForwardButton.Content=l["forward"];
        SelectionHideButton.Content=l["hide"];
    }

    private void ViewModel_StateChanged(object? sender, EventArgs e)
    {
        if (_viewModel is null) return;
        ConnectionStatusText.Text = $"{StatusLabel(_viewModel.SyncStatus)} · {AppServices.Current.Connection.Api?.BaseUrl}";
        OlderMessagesProgress.IsActive=_viewModel.IsLoadingOlder;
        OlderMessagesProgress.Visibility=_viewModel.IsLoadingOlder?Visibility.Visible:Visibility.Collapsed;
        UpdateThreadSubtitle();
        UpdateTrayContacts();
    }

    private void ViewModel_RealtimeChanged(object? sender,EventArgs e)
    {
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

    private void ComposerRegion_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        // Reserve the measured editor height for multiline text, font scaling,
        // recording and selection bars. The background remains continuous.
        var bottom = Math.Ceiling(e.NewSize.Height) + 28;
        if (Math.Abs(MessageList.Padding.Bottom - bottom) < 0.5) return;
        var pinned = _messageScroller is not null && _messageScroller.ScrollableHeight - _messageScroller.VerticalOffset < 24;
        var keepingBottom = _keepingMessageBottom;
        _keepingMessageBottom = true;
        try
        {
            MessageList.Padding = new Thickness(20, 12, 20, bottom);
            JumpToBottomButton.Margin = new Thickness(0, 0, 16, bottom + 8);
            if (pinned)
            {
                MessageList.UpdateLayout();
                _messageScroller?.ChangeView(null, _messageScroller.ScrollableHeight, null, true);
            }
        }
        finally { _keepingMessageBottom = keepingBottom; }
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
        var mark=new MenuFlyoutItem { Text=AppServices.Current.Localization[chat.HasUnread?"markRead":"markUnread"], Icon=new FontIcon { Glyph="\uE8C3" } };
        mark.Click+=async(_,_)=>await _viewModel.SetChatUnreadAsync(chat,!chat.HasUnread);
        menu.Items.Add(mark);
        var hide=new MenuFlyoutItem{Text=AppServices.Current.Localization["hide"],Icon=new FontIcon{Glyph="\uED1A"}};
        hide.Click+=async(_,_)=>
        {
            var wasSelected=_viewModel.SelectedChat is{} selected&&(selected.Id==chat.Id||chat.RouteIds?.Contains(selected.Id)==true);
            await _viewModel.HideChatAsync(chat);
            _undoHiddenChat = chat;
            HideUndoMessage.Text = AppServices.Current.Localization["chatHidden"];
            HideUndoButton.Content = AppServices.Current.Localization["undo"];
            _hideUndoTimer.Stop();
            // Let the context menu finish closing before opening another native flyout.
            DispatcherQueue.TryEnqueue(() =>
            {
                if(_undoHiddenChat is null||_shutDown)return;
                HideUndoFlyout.ShowAt(ChatList,new Microsoft.UI.Xaml.Controls.Primitives.FlyoutShowOptions{Placement=Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedLeft});
                _hideUndoTimer.Start();
            });
            if(!wasSelected)return;
            ChatList.SelectedItem=null;
            if(_viewModel.Chats.FirstOrDefault() is{} next){ChatList.SelectedItem=next;await SelectChatAsync(next);return;}
            EmptyState.Visibility=Visibility.Visible;Composer.IsEnabled=false;UpdateComposerActions();
        };
        menu.Items.Add(hide);menu.ShowAt(ChatList,e.GetPosition(ChatList));e.Handled=true;
    }

    private async void HideUndoButton_Click(object sender, RoutedEventArgs e)
    {
        var chat = _undoHiddenChat;
        _hideUndoTimer.Stop(); _undoHiddenChat = null; HideUndoFlyout.Hide();
        if (chat is not null && _viewModel is not null) await _viewModel.RestoreHiddenChatsAsync([chat.Id]);
    }

    private async Task SelectChatAsync(ChatSummary chat)
    {
        if (_viewModel is null) return;
        ShowConversationPane();
        if (_viewModel.SelectedChat is { } current
            && _viewModel.Messages.Count > 0
            && current.ListKey==chat.ListKey
            && ContactConversationSemantics.SameRoutes(chat,current.RouteIds??[current.Id]))
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
            EmojiButton.IsEnabled = chat.CanSendText;
            Composer.PlaceholderText = chat.CanSendText ? AppServices.Current.Localization["message"] : "—";
            UpdateComposerActions();
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

    private void ChatRows_Mutated(object? sender,ChatListMutationEventArgs e)
    {
        // WinUI may clear SelectedItem while a Move is projected as removal and
        // insertion. Restore the existing canonical row without reloading history.
        if (_viewModel?.SelectedChat is { } selected) {
            var canonical = _viewModel.Chats.FirstOrDefault(row => row.ListKey == selected.ListKey);
            if (!ReferenceEquals(ChatList.SelectedItem, canonical)) ChatList.SelectedItem = canonical;
        }
#if DEBUG
        System.Diagnostics.Debug.WriteLine($"[ChatList] move={e.Moves.Count} insert={e.Inserted} remove={e.Removed} rows={_viewModel?.Chats.Count??0}");
#endif
        if(!e.Animate||e.Inserted!=0||e.Removed!=0||e.Moves.Count!=1)return;
        var move=e.Moves[0];
        DispatcherQueue.TryEnqueue(async()=>await AnimateChatMoveAsync(move));
    }

    private async Task AnimateChatMoveAsync(ChatRowMove move)
    {
        await Task.Yield();
        ChatList.UpdateLayout();
        if(ChatList.ItemsPanelRoot is not ItemsStackPanel panel||move.NewIndex<0||move.NewIndex>=ChatList.Items.Count)return;
        bool animationsEnabled;
        try{animationsEnabled=new UISettings().AnimationsEnabled;}
        catch{animationsEnabled=true;}
        if(!animationsEnabled||!IsVisibleMove(move.OldIndex,move.NewIndex,panel))return;
        if(ChatList.ContainerFromIndex(move.NewIndex) is not ListViewItem target||target.ActualHeight<=0)return;

        var direction=move.NewIndex>move.OldIndex?1:-1;
        var offset=(float)target.ActualHeight;
        var start=Math.Max(Math.Min(move.NewIndex+1,move.OldIndex),panel.FirstCacheIndex);
        var end=Math.Min(Math.Max(move.NewIndex,move.OldIndex+1),panel.LastCacheIndex+1);
        var targetVisual=ElementCompositionPreview.GetElementVisual(target);
        var compositor=targetVisual.Compositor;
        var easing=compositor.CreateCubicBezierEasingFunction(new Vector2(0.1f,0.9f),new Vector2(0.2f,1f));
        var duration=TimeSpan.FromMilliseconds(167);

        var reveal=compositor.CreateScalarKeyFrameAnimation();
        reveal.InsertKeyFrame(0,offset);
        reveal.InsertKeyFrame(1,0,easing);
        reveal.Duration=duration;
        targetVisual.Clip??=compositor.CreateInsetClip();
        targetVisual.Clip.StartAnimation("BottomInset",reveal);
        if(direction>0)
        {
            ElementCompositionPreview.SetIsTranslationEnabled(target,true);
            targetVisual.StartAnimation("Translation.Y",reveal);
        }

        for(var index=start;index<end;index++)
        {
            if(index==move.NewIndex||ChatList.ContainerFromIndex(index) is not ListViewItem container)continue;
            ElementCompositionPreview.SetIsTranslationEnabled(container,true);
            var visual=ElementCompositionPreview.GetElementVisual(container);
            var shift=compositor.CreateScalarKeyFrameAnimation();
            shift.InsertKeyFrame(0,offset*direction);
            shift.InsertKeyFrame(1,0,easing);
            shift.Duration=duration;
            visual.StartAnimation("Translation.Y",shift);
        }
    }

    private static bool IsVisibleMove(int oldIndex,int newIndex,ItemsStackPanel panel)
    {
        if(oldIndex<0)return newIndex>=panel.FirstVisibleIndex&&newIndex<=panel.LastVisibleIndex;
        if(newIndex<0)return oldIndex>=panel.FirstVisibleIndex&&oldIndex<=panel.LastVisibleIndex;
        return oldIndex>=panel.FirstVisibleIndex||(newIndex>=panel.FirstVisibleIndex&&newIndex<=panel.LastVisibleIndex);
    }

    private void Messages_CollectionChanged(object? sender,NotifyCollectionChangedEventArgs e)
    {
        if(e.Action!=NotifyCollectionChangedAction.Add||e.NewItems is null)return;
        foreach(var row in e.NewItems.OfType<MessageRow>())
        {
            if(row.TryConsumeEntrance(out var kind))_pendingMessageEntrances.Add((row,kind));
        }
        if(_pendingMessageEntrances.Count==0||_messageEntranceDrainScheduled)return;
        _messageEntranceDrainScheduled=true;
        DispatcherQueue.TryEnqueue(async()=>await AnimatePendingMessageEntrancesAsync());
    }

    private void MessageList_ContainerContentChanging(ListViewBase sender,ContainerContentChangingEventArgs args)
    {
        // A container must stay visible even when an entrance is skipped or
        // superseded by a snapshot. Animation owns only a temporary visual offset.
        args.ItemContainer.Opacity=1;
        if(args.InRecycleQueue)
        {
            ResetMessageVisual(args.ItemContainer);
            if(args.ItemContainer.ContentTemplateRoot is UIElement content)ResetMessageVisual(content);
            return;
        }
    }

    private static void ResetMessageVisual(UIElement element)
    {
        // Recycled history rows may never have had an entrance animation.
        // Translation is an opt-in facade; stopping it before registration
        // throws E_INVALIDARG from the native Composition layer.
        ElementCompositionPreview.SetIsTranslationEnabled(element,true);
        var visual=ElementCompositionPreview.GetElementVisual(element);
        visual.StopAnimation("Opacity");
        visual.StopAnimation("Scale");
        visual.StopAnimation("Translation.Y");
        visual.Opacity=1;
        visual.Scale=Vector3.One;
        visual.Properties.InsertVector3("Translation",Vector3.Zero);
    }

    private async Task AnimatePendingMessageEntrancesAsync()
    {
        _messageEntranceDrainScheduled=false;
        var pending=_pendingMessageEntrances.ToArray();
        _pendingMessageEntrances.Clear();
        await Task.Yield();
        MessageList.UpdateLayout();

        var containers=pending
            .Select(item=>(item.Row,item.Kind,Index:_viewModel?.Messages.IndexOf(item.Row)??-1,Container:MessageList.ContainerFromItem(item.Row) as ListViewItem))
            .Where(item=>item.Index>=0&&item.Container is not null)
            .ToArray();
        if(containers.Length==0)return;

        bool animationsEnabled;
        try{animationsEnabled=new UISettings().AnimationsEnabled;}
        catch{animationsEnabled=true;}
        var now=DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        foreach(var item in containers)item.Container!.Opacity=1;
        var actual=containers.Where(item=>!item.Row.Value.IsSeparator
            && Math.Abs(now-item.Row.Value.DateCreated)<=TimeSpan.FromSeconds(15).TotalMilliseconds)
            .ToArray();
        var panel=MessageList.ItemsPanelRoot as ItemsStackPanel;
        if(!animationsEnabled||panel is null||actual.Length==0)
        {
            foreach(var item in containers)item.Container!.Opacity=1;
            return;
        }

        var first=actual.Min(item=>item.Index);
        var last=actual.Max(item=>item.Index);
        var appendedFrom=(_viewModel?.Messages.Count??0)-containers.Length;
        var visible=first>=appendedFrom&&last>=panel.FirstVisibleIndex&&first<=panel.LastVisibleIndex;
        if(!visible)
        {
            foreach(var item in containers)item.Container!.Opacity=1;
            return;
        }

        var compositor=ElementCompositionPreview.GetElementVisual(actual[0].Container!).Compositor;
        var easing=compositor.CreateCubicBezierEasingFunction(new Vector2(0.1f,0.9f),new Vector2(0.2f,1f));
        var duration=TimeSpan.FromMilliseconds(240);
        var insertedHeight=(float)containers.Sum(item=>item.Container!.ActualHeight);

        // Preserve the pre-insert visual position of rows pushed upward by an
        // append, then settle them into the layout selected by KeepLastItemInView.
        for(var index=Math.Max(0,panel.FirstVisibleIndex);index<first;index++)
        {
            if(MessageList.ContainerFromIndex(index) is not ListViewItem container)continue;
            var element=container.ContentTemplateRoot as UIElement??container;
            ElementCompositionPreview.SetIsTranslationEnabled(element,true);
            var visual=ElementCompositionPreview.GetElementVisual(element);
            var shift=compositor.CreateScalarKeyFrameAnimation();
            shift.InsertKeyFrame(0,insertedHeight);
            shift.InsertKeyFrame(1,0,easing);
            shift.Duration=duration;
            visual.StartAnimation("Translation.Y",shift);
        }

        foreach(var item in actual)
        {
            var container=item.Container!;
            container.Opacity=1;
            ElementCompositionPreview.SetIsTranslationEnabled(container,true);
            var visual=ElementCompositionPreview.GetElementVisual(container);
            visual.Opacity=1;
            visual.Scale=Vector3.One;
            visual.CenterPoint=new Vector3(item.Row.Value.IsOutgoing?(float)container.ActualWidth:0,(float)container.ActualHeight,0);

            var rise=compositor.CreateScalarKeyFrameAnimation();
            rise.InsertKeyFrame(0,item.Kind==MessageEntranceKind.LocalSend?10:7);
            rise.InsertKeyFrame(1,0,easing);
            rise.Duration=duration;
            var fade=compositor.CreateScalarKeyFrameAnimation();
            fade.InsertKeyFrame(0,0);
            fade.InsertKeyFrame(1,1,easing);
            fade.Duration=TimeSpan.FromMilliseconds(190);
            visual.StartAnimation("Translation.Y",rise);
            visual.StartAnimation("Opacity",fade);

            if(item.Kind==MessageEntranceKind.LocalSend)
            {
                var scale=compositor.CreateVector3KeyFrameAnimation();
                scale.InsertKeyFrame(0,new Vector3(0.985f,0.985f,1));
                scale.InsertKeyFrame(1,Vector3.One,easing);
                scale.Duration=TimeSpan.FromMilliseconds(210);
                visual.StartAnimation("Scale",scale);
            }
        }
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

    public void OpenThirdPartyNotices()=>DetailFrame.Navigate(typeof(ThirdPartyNoticesPage),new ShellNavigationContext(this,null,"about"),ForwardTransition());

    public void OpenHiddenMessages()=>DetailFrame.Navigate(typeof(HiddenMessagesPage),new ShellNavigationContext(this,null,"data"),ForwardTransition());

    public void GoBackInDetail()
    {
        if(DetailFrame.CanGoBack)DetailFrame.GoBack(new SlideNavigationTransitionInfo{Effect=SlideNavigationTransitionEffect.FromLeft});
        else ShowSettingsSection("data");
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
        if (_shutDown) return; _shutDown = true;
        _chatSelectionAnimation.Dispose();
        _settingsSelectionAnimation.Dispose();
        _hideUndoTimer.Stop(); _undoHiddenChat = null; HideUndoFlyout.Hide();
        _timestampTimer.Stop();
        _voiceTimer.Stop();
        _voiceRecorder.Dispose();
        AppServices.Current.Appearance.AppearanceChanged -= Appearance_AppearanceChanged;
        Controls.MessageBubble.ReplyJumpRequested -= OnReplyJumpRequested;
        Controls.MessageBubble.RetryRequested -= OnRetryRequested;
        Controls.MessageBubble.ScreenEffectRequested -= OnScreenEffectRequested;
        if(_messageScroller is not null){_messageScroller.ViewChanged-=MessageScroller_ViewChanged;_messageScroller=null;}
        if (_viewModel is { } viewModel)
        {
            _viewModel = null;
            viewModel.StateChanged -= ViewModel_StateChanged;
            viewModel.RealtimeChanged -= ViewModel_RealtimeChanged;
            viewModel.Chats.Mutated -= ChatRows_Mutated;
            viewModel.Messages.CollectionChanged -= Messages_CollectionChanged;
            await viewModel.DisposeAsync();
        }
    }

    /// <summary>Scrolls to (and briefly flashes) the message a reply points at.</summary>
    private async void OnReplyJumpRequested(object? sender, string target)
    {
        if (_viewModel is null) return;
        var row = _viewModel.Messages.FirstOrDefault(item =>
            !item.Value.IsSeparator
            && (string.Equals(item.Value.Id, target, StringComparison.OrdinalIgnoreCase)
                || string.Equals(ThreadPresentation.NormalizeTarget(item.Value.Id), target, StringComparison.OrdinalIgnoreCase)));
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

    public IReadOnlyList<ChatSummary> GetContactRoutes(ChatSummary chat)=>_viewModel?.GetContactRoutes(chat)??[];
    public IReadOnlyList<ChatSummary> GetLinkableContactAccounts(ChatSummary chat)=>_viewModel?.GetLinkableContactAccounts(chat)??[];

    public async Task RefreshContactsAsync()
    {
        if(_viewModel is null)return;await _viewModel.RefreshContactsAsync();
        if(_viewModel.SelectedChat is{} chat)
        {
            ChatList.SelectedItem=_viewModel.Chats.FirstOrDefault(row=>row.ListKey==chat.ListKey);
            ThreadAvatar.DisplayName=chat.Title;ThreadAvatar.ProfilePicture=Ui.Image(chat.AvatarPath);ThreadTitle.Text=chat.Title;
            Composer.IsEnabled=chat.CanSendText;EmojiButton.IsEnabled=chat.CanSendText;UpdateComposerActions();
        }
    }

    public int HiddenChatCount=>_viewModel?.HiddenChatCount??0;
    public int HiddenMessageCount=>_viewModel?.HiddenMessageCount??0;
    public IReadOnlyList<ChatSummary> HiddenChats=>_viewModel?.HiddenChats??[];
    public async Task<int> RestoreHiddenChatsAsync(IEnumerable<string> chatIds)=>_viewModel is null?0:await _viewModel.RestoreHiddenChatsAsync(chatIds);
    public Task<IReadOnlyList<Message>> GetHiddenMessagesAsync()=>_viewModel?.GetHiddenMessagesAsync()??Task.FromResult<IReadOnlyList<Message>>([]);
    public async Task<int> RestoreHiddenMessagesAsync(IEnumerable<string> messageIds)=>_viewModel is null?0:await _viewModel.RestoreHiddenMessagesAsync(messageIds);

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

    private string? _appliedBackgroundKey;

    private void ApplyChatAppearance()
    {
        var path = AppServices.Current.Appearance.ChatBackgroundPath;
        var hasBackground = !string.IsNullOrWhiteSpace(path) && File.Exists(path);
        // A picked image is always copied to the same file name, so the write
        // time tells a new image from a plain appearance refresh — changing the
        // bubble colour no longer reloads (and flashes) the background.
        var key = hasBackground ? $"{path}|{File.GetLastWriteTimeUtc(path!).Ticks}" : null;
        if (key != _appliedBackgroundKey)
        {
            _appliedBackgroundKey = key;
            ChatBackgroundImage.Source = hasBackground
                ? new BitmapImage { CreateOptions = BitmapCreateOptions.IgnoreImageCache, UriSource = new Uri(path!, UriKind.Absolute) }
                : null;
        }
        var visibility = hasBackground ? Visibility.Visible : Visibility.Collapsed;
        ChatBackgroundImage.Visibility = visibility;
        ChatBackgroundScrim.Visibility = visibility;
        MicaGo.App.Services.ChatSurfaceBrushes.Apply(solid: hasBackground);
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
    private void Composer_TextChanged(object sender, TextChangedEventArgs e) => UpdateComposerActions();

    private async Task ShowSendErrorAsync(string message)
    {
        var l=AppServices.Current.Localization;
        await new ContentDialog{Title=l["sendFailed"],Content=message,CloseButtonText=l["close"],XamlRoot=XamlRoot}.ShowAsync();
    }
    private void Thread_DragOver(object sender,DragEventArgs e)
    {
        if(e.Handled)return;
        if(_viewModel?.SelectedChat is not{CanSendAttachments:true}||!(e.DataView.Contains(StandardDataFormats.StorageItems)||e.DataView.Contains(StandardDataFormats.Bitmap)))return;
        e.AcceptedOperation=DataPackageOperation.Copy;e.Handled=true;
        e.DragUIOverride.Caption=AppServices.Current.Localization["sendAttachments"];
    }
    private async void Thread_Drop(object sender,DragEventArgs e)
    {
        if(e.Handled)return;
        var target=_viewModel?.SelectedChat?.ListKey;if(target is null)return;
        var deferral=e.GetDeferral();e.Handled=true;
        try {await SendDataPackageAsync(e.DataView,target);}
        catch(Exception error){await ShowSendErrorAsync(error.Message);}
        finally{deferral.Complete();}
    }

    private async void Composer_Paste(object sender,TextControlPasteEventArgs e)
    {
        DataPackageView package;try{package=Clipboard.GetContent();}catch{return;}
        if(!package.Contains(StandardDataFormats.StorageItems)&&!package.Contains(StandardDataFormats.Bitmap))return;
        var target=_viewModel?.SelectedChat?.ListKey;if(target is null)return;e.Handled=true;
        try{await SendDataPackageAsync(package,target);}catch(Exception error){await ShowSendErrorAsync(error.Message);}
    }
    private async Task SendDataPackageAsync(DataPackageView package,string target)
    {
        var paths=new List<string>();var temporary=new List<string>();
        try {
            if(package.Contains(StandardDataFormats.StorageItems))foreach(var file in (await package.GetStorageItemsAsync()).OfType<StorageFile>()) {
                if(!string.IsNullOrWhiteSpace(file.Path)){paths.Add(file.Path);continue;}
                var copied=await file.CopyAsync(ApplicationData.Current.TemporaryFolder,file.Name,NameCollisionOption.GenerateUniqueName);
                paths.Add(copied.Path);temporary.Add(copied.Path);
            }
            if(paths.Count==0&&package.Contains(StandardDataFormats.Bitmap)) {
                var bitmap=await package.GetBitmapAsync();using var source=await bitmap.OpenReadAsync();
                var decoder=await BitmapDecoder.CreateAsync(source);
                var file=await ApplicationData.Current.TemporaryFolder.CreateFileAsync($"micaGO-paste-{Guid.NewGuid():N}.png",CreationCollisionOption.GenerateUniqueName);
                using(var destination=await file.OpenAsync(FileAccessMode.ReadWrite)) {
                    var encoder=await BitmapEncoder.CreateForTranscodingAsync(destination,decoder);await encoder.FlushAsync();
                }
                paths.Add(file.Path);temporary.Add(file.Path);
            }
            if(_viewModel?.SelectedChat?.ListKey!=target)return;
            if(paths.Count>0)await SendComposerAttachmentsAsync(paths);
        }
        finally{foreach(var path in temporary)try{File.Delete(path);}catch(IOException){}catch(UnauthorizedAccessException){}}
    }

    private async Task SendComposerAttachmentsAsync(IReadOnlyList<string> paths)
    {
        if(_viewModel?.SelectedChat is null||paths.Count==0)return;
        _keepingMessageBottom=true;
        try
        {
            await _viewModel.SendAttachmentsAsync(paths);
            UpdateThreadSubtitle();
        }
        finally{_keepingMessageBottom=false;}
    }

    private void UpdateComposerActions()
    {
        var canSend = _viewModel?.SelectedChat?.CanSendText == true;
        var hasText = !string.IsNullOrWhiteSpace(Composer.Text);
        SendButton.IsEnabled = canSend && hasText;
        var canAttach=_viewModel?.SelectedChat?.CanSendAttachments==true;
        RecordVoiceItem.IsEnabled = canAttach;
        AttachFilesItem.IsEnabled = canAttach;
        AttachButton.IsEnabled = canAttach;
        EmojiButton.IsEnabled = canSend;
    }

    private void EmojiButton_Click(object sender, RoutedEventArgs e)
    {
        if (!Composer.IsEnabled) return;
        Composer.Focus(FocusState.Programmatic);
        var shown = false;
        try
        {
            shown = CoreInputView.GetForCurrentView().TryShow(CoreInputViewKind.Emoji);
        }
        catch
        {
            // WinUI desktop sessions do not always expose a CoreInputView.
        }
        if (!shown) ShowSystemEmojiShortcut();
    }

    private static void ShowSystemEmojiShortcut()
    {
        var inputs = new[]
        {
            KeyboardInput(VirtualKeyLeftWindows, keyUp: false),
            KeyboardInput(VirtualKeyOemPeriod, keyUp: false),
            KeyboardInput(VirtualKeyOemPeriod, keyUp: true),
            KeyboardInput(VirtualKeyLeftWindows, keyUp: true),
        };
        _ = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>());
    }

    private static Input KeyboardInput(ushort virtualKey, bool keyUp) => new()
    {
        Type = InputKeyboard,
        Union = new InputUnion
        {
            Keyboard = new KeyboardInputData
            {
                VirtualKey = virtualKey,
                Flags = keyUp ? KeyEventKeyUp : 0,
            },
        },
    };

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint inputCount, Input[] inputs, int inputSize);

    [StructLayout(LayoutKind.Sequential)]
    private struct Input
    {
        public uint Type;
        public InputUnion Union;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MouseInputData Mouse;
        [FieldOffset(0)] public KeyboardInputData Keyboard;
        [FieldOffset(0)] public HardwareInputData Hardware;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInputData
    {
        public int X;
        public int Y;
        public uint MouseData;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInputData
    {
        public ushort VirtualKey;
        public ushort ScanCode;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HardwareInputData
    {
        public uint Message;
        public ushort ParameterLow;
        public ushort ParameterHigh;
    }

    private async Task SendCurrentTextAsync()
    {
        var text = Composer.Text.Trim(); if (_viewModel is null || string.IsNullOrEmpty(text)) return;
        Composer.Text = string.Empty; UpdateComposerActions();
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
        catch(Exception error){if(string.IsNullOrEmpty(Composer.Text))Composer.Text=text;await ShowSendErrorAsync(error.Message);}
        finally { _keepingMessageBottom = false; }
    }

    private async void AttachFilesItem_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel?.SelectedChat is null) return;
        var picker = new Windows.Storage.Pickers.FileOpenPicker();
        picker.FileTypeFilter.Add("*");
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);
        var target=_viewModel.SelectedChat.ListKey;
        var files = await picker.PickMultipleFilesAsync();
        if (files.Count == 0||_viewModel?.SelectedChat?.ListKey!=target) return;
        try{await SendComposerAttachmentsAsync(files.Select(file=>file.Path).ToArray());}
        catch(Exception error){await ShowSendErrorAsync(error.Message);}
    }

    private void MessageList_ContextRequested(UIElement sender, ContextRequestedEventArgs e)
    {
        var row = FindMessageRow(e.OriginalSource as DependencyObject);
        if (row is null) return;
        if (e.TryGetPosition(MessageList, out var position)) ShowMessageMenu(row, MessageList, position);
        else if (MessageList.ContainerFromItem(row) is FrameworkElement anchor) ShowMessageMenu(row, anchor);
        else return;
        e.Handled = true;
    }

    private void MessageText_ContextMenuOpening(FrameworkElement sender, ContextMenuEventArgs e)
    {
        if (FindMessageRow(sender) is not { } row) return;
        ShowMessageMenu(row, sender);
        e.Handled = true;
    }

    private static MessageRow? FindMessageRow(DependencyObject? source)
    {
        while (source is not null)
        {
            if (source is FrameworkElement { DataContext: MessageRow row }) return row;
            source = VisualTreeHelper.GetParent(source);
        }
        return null;
    }

    private void MessageList_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        var shift = (InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift) & CoreVirtualKeyStates.Down) != 0;
        if (e.Key != VirtualKey.Application && !(e.Key == VirtualKey.F10 && shift)) return;
        var focused = FocusManager.GetFocusedElement(XamlRoot) as DependencyObject;
        var row = FindMessageRow(focused);
        if (row is null || MessageList.ContainerFromItem(row) is not FrameworkElement anchor) return;
        ShowMessageMenu(row, anchor);
        e.Handled = true;
    }

    // F6 changes regions; arrows/Tab retain their native control behavior.
    private async void Shell_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.F6 || ConversationPane.Visibility != Visibility.Visible) return;
        var reverse = (InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift) & CoreVirtualKeyStates.Down) != 0;
        var focused = FocusManager.GetFocusedElement(XamlRoot) as DependencyObject;
        var current = IsInside(focused, MessageList) ? 1 : IsInside(focused, ComposerRegion) ? 2 : 0;
        var next = (current + (reverse ? 2 : 1)) % 3;
        e.Handled = true;
        if (next == 0)
        {
            SearchBox.Focus(FocusState.Keyboard);
            return;
        }
        if (next == 2)
        {
            if (Composer.IsEnabled) Composer.Focus(FocusState.Keyboard);
            else SearchBox.Focus(FocusState.Keyboard);
            return;
        }
        if (_viewModel?.Messages.LastOrDefault() is not { } last)
        {
            MessageList.Focus(FocusState.Keyboard);
            return;
        }
        MessageList.ScrollIntoView(last);
        await Task.Yield();
        if (_shutDown || ConversationPane.Visibility != Visibility.Visible) return;
        MessageList.UpdateLayout();
        if (MessageList.ContainerFromItem(last) is Control item) item.Focus(FocusState.Keyboard);
        else MessageList.Focus(FocusState.Keyboard);
    }

    private static bool IsInside(DependencyObject? element, DependencyObject parent)
    {
        while (element is not null)
        {
            if (ReferenceEquals(element, parent)) return true;
            element = VisualTreeHelper.GetParent(element);
        }
        return false;
    }

    private async void OnRetryRequested(object? sender,Message message)
    {
        if(_viewModel is null)return;
        try{await _viewModel.RetryMessageAsync(message);}catch(Exception error){await ShowSendErrorAsync(error.Message);}
    }
    private void ShowMessageMenu(MessageRow row, FrameworkElement anchor, Windows.Foundation.Point? position = null)
    {
        if (_viewModel is null) return;
        var message=row.Value;
        var menu = new MenuFlyout();
        var visibleText=MessageSemantics.VisibleText(message.Text);
        if(visibleText.Length>0) {
            var copy=new MenuFlyoutItem{Text=AppServices.Current.Localization["copy"], Icon = new FontIcon { Glyph = "\uE8C8" } };
            copy.Click+=(_,_)=>{var package=new DataPackage();package.SetText(visibleText);Clipboard.SetContent(package);};menu.Items.Add(copy);
        }
        if(message.IsPending && message.DeliveryState==MessageDeliveryState.Failed)
        {
            var retry=new MenuFlyoutItem{Text=AppServices.Current.Localization["retry"], Icon = new FontIcon { Glyph = "\uE72C" } };retry.Click+=(_,_)=>OnRetryRequested(this,message);menu.Items.Add(retry);
        }
        if(message.IsPending&&message.DeliveryState==MessageDeliveryState.Sending&&message.Media.Count>0){var cancel=new MenuFlyoutItem{Text=AppServices.Current.Localization["cancelUpload"], Icon = new FontIcon { Glyph = "\uE711" } };cancel.Click+=(_,_)=>_viewModel.CancelAttachmentUpload(message);menu.Items.Add(cancel);}
        if (message.IsOutgoing && !message.IsPending)
        {
            if(_viewModel.ActionCapabilities.CanEdit){var edit = new MenuFlyoutItem { Text = AppServices.Current.Localization["edit"], Icon = new FontIcon { Glyph = "\uE70F" } }; edit.Click += async (_, _) => { var box = new TextBox { Text = message.Text, AcceptsReturn = true }; var dialog = new ContentDialog { Title = AppServices.Current.Localization["edit"], Content = box, PrimaryButtonText = AppServices.Current.Localization["edit"], CloseButtonText = AppServices.Current.Localization["cancel"], XamlRoot = XamlRoot }; if (await dialog.ShowAsync() == ContentDialogResult.Primary) await _viewModel.EditAsync(message, box.Text); }; menu.Items.Add(edit);}
            if(_viewModel.ActionCapabilities.CanRetract){var retract = new MenuFlyoutItem { Text = AppServices.Current.Localization["unsend"], Icon = new FontIcon { Glyph = "\uE7A7" } }; retract.Click += async (_, _) => await _viewModel.RetractAsync(message); menu.Items.Add(retract);}
        }
        if(message.IsPending||_viewModel.ActionCapabilities.CanDelete){var delete = new MenuFlyoutItem { Text = AppServices.Current.Localization["delete"], Icon = new FontIcon { Glyph = "\uE74D" } }; delete.Click += async (_, _) => await _viewModel.DeleteAsync(message); menu.Items.Add(delete);}
        if(!message.IsSeparator&&!message.IsPresentationSystem)
        {
            if(!message.IsPending)
            {
                var forward=new MenuFlyoutItem{Text=AppServices.Current.Localization["forward"], Icon = new FontIcon { Glyph = "\uE72A" } };
                forward.Click+=async(_,_)=>await ForwardWithPickerAsync([message]);menu.Items.Add(forward);
                var hide=new MenuFlyoutItem{Text=AppServices.Current.Localization["hide"],Icon=new FontIcon{Glyph="\uED1A"}};
                hide.Click+=async(_,_)=>await _viewModel.HideMessagesAsync([message]);
                menu.Items.Add(hide);
            }
            var select=new MenuFlyoutItem{Text=AppServices.Current.Localization["select"],Icon=new FontIcon{Glyph="\uE762"}};
            select.Click+=(_,_)=>EnterSelectMode(message);
            menu.Items.Add(select);
        }
        if (position is { } point) menu.ShowAt(anchor, point);
        else menu.ShowAt(anchor);
    }

    // ----- voice messages -----

    private async void RecordVoiceItem_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel?.SelectedChat is null || _voiceRecorder.IsRecording) return;
        try
        {
            await _voiceRecorder.StartAsync();
        }
        catch (Exception exception)
        {
            ConnectionStatusText.Text = string.Format(AppServices.Current.Localization["micUnavailable"], exception.Message);
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
        catch(Exception error){await ShowSendErrorAsync(error.Message);}
        finally { _keepingMessageBottom = false; }
    }

    // ----- multi-select (forward / hide) -----

    private void EnterSelectMode(Message? initial)
    {
        if (_selectMode) return;
        _selectMode = true;
        MessageList.ItemContainerStyle = (Style)Application.Current.Resources["MicaGoSelectedMessageListStyle"];
        MessageList.SelectionMode = ListViewSelectionMode.Multiple;
        ComposerBorder.Visibility = Visibility.Collapsed;
        VoiceBar.Visibility = Visibility.Collapsed;
        SelectionBar.Visibility = Visibility.Visible;
        if (initial is not null)
        {
            var row=_viewModel?.Messages.FirstOrDefault(item=>item.PresentationKey==initial.PresentationKey);
            if(row is not null)MessageList.SelectedItems.Add(row);
        }
        UpdateSelectionBar();
    }

    private void ExitSelectMode()
    {
        if (!_selectMode) return;
        _selectMode = false;
        MessageList.SelectedItems.Clear();
        MessageList.SelectionMode = ListViewSelectionMode.None;
        MessageList.ItemContainerStyle = (Style)Application.Current.Resources["MicaGoMessageListStyle"];
        SelectionBar.Visibility = Visibility.Collapsed;
        ComposerBorder.Visibility = Visibility.Visible;
    }

    private void MessageList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_selectMode) UpdateSelectionBar();
    }

    private IReadOnlyList<Message> SelectedMessages() =>
        MessageList.SelectedItems.OfType<MessageRow>().Select(row=>row.Value)
            .Where(message => !message.IsSeparator && !message.IsPresentationSystem)
            .OrderBy(message => message.DateCreated)
            .ToArray();

    private void UpdateSelectionBar()
    {
        var selected=SelectedMessages();
        var count = selected.Count;var forwardCount=selected.Count(row=>!row.IsPending);
        var l = AppServices.Current.Localization;
        SelectionCountText.Text = string.Format(l["selectedCount"], count);
        SelectionForwardButton.Content = $"{l["forward"]} ({forwardCount})";
        SelectionHideButton.Content = $"{l["hide"]} ({count})";
        SelectionForwardButton.IsEnabled = forwardCount > 0;
        SelectionHideButton.IsEnabled = forwardCount > 0;
    }

    private void SelectionCancelButton_Click(object sender, RoutedEventArgs e) => ExitSelectMode();

    private async void SelectionForwardButton_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel is null) return;
        var selected = SelectedMessages();
        if (selected.Count == 0) return;
        await ForwardWithPickerAsync(selected);
    }
    private async Task ForwardWithPickerAsync(IReadOnlyList<Message> selected)
    {
        if(_viewModel is null)return;
        selected=selected.Where(row=>!row.IsPending&&!row.IsPresentationSystem&&!row.IsSeparator).ToArray();
        if(selected.Count==0)return;
        var l = AppServices.Current.Localization;
        var targets=_viewModel.ForwardTargets(selected);
        var picker = new ListView
        {
            ItemsSource = targets,
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
        var search=new TextBox{PlaceholderText=l["search"]};
        search.TextChanged+=(_,_)=>picker.ItemsSource=targets.Where(chat=>chat.Title.Contains(search.Text,StringComparison.CurrentCultureIgnoreCase)).ToArray();
        var panel=new StackPanel{Spacing=12,MinWidth=280};panel.Children.Add(search);panel.Children.Add(picker);dialog.Content=panel;
        dialog.IsPrimaryButtonEnabled=false;
        picker.SelectionChanged+=(_,_)=>dialog.IsPrimaryButtonEnabled=picker.SelectedItem is ChatSummary;
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || picker.SelectedItem is not ChatSummary target) return;
        ExitSelectMode();
        try{await _viewModel.ForwardMessagesAsync(target, selected);}
        catch(Exception error){await ShowSendErrorAsync(error.Message);}
    }

    private async void SelectionHideButton_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel is null) return;
        var selected = SelectedMessages();
        ExitSelectMode();
        if (selected.Count > 0) await _viewModel.HideMessagesAsync(selected);
    }

    // The realtime loop reports fixed English status words; translate them for display.
    private static string StatusLabel(string status)
    {
        var l = AppServices.Current.Localization;
        return status switch
        {
            "Live" => l["statusLive"],
            "Catching up" => l["statusCatchingUp"],
            "Reconnecting" => l["statusReconnecting"],
            "Offline cache" => l["statusOfflineCache"],
            _ => status,
        };
    }

    private void UpdateThreadSubtitle()
    {
        if (_viewModel?.SelectedChat is not { } chat) return;
        var latestMessage = _viewModel.Messages.Select(row=>row.Value).Where(message => !message.IsSeparator).Select(message => message.DateCreated).DefaultIfEmpty(0).Max();
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

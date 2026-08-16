using System.Collections.ObjectModel;
using Microsoft.UI.Dispatching;
using MicaGo.App.Services;
using MicaGo.Core.Models;
using MicaGo.Infrastructure.Api;
using MicaGo.Infrastructure.Connection;
using MicaGo.Infrastructure.Contracts;

namespace MicaGo.App.ViewModels;

public sealed class ShellViewModel : IAsyncDisposable
{
    private readonly DispatcherQueue _dispatcher;
    private readonly IMicaGoApi _api;
    private readonly AppServices _services;
    private RealtimeSyncService? _realtime;
    private List<ChatSummary> _allChats = [];
    private List<Message> _rawMessages = [];
    private readonly Dictionary<string, string> _pendingAttachmentPaths = [];
    private readonly Dictionary<string,CancellationTokenSource> _uploadCancellations=[];
    private CancellationTokenSource? _selectionCts;
    private IReadOnlySet<string> _hiddenMessageKeys = new HashSet<string>();
    private IReadOnlySet<string> _hiddenChatGuids = new HashSet<string>();
    private HashSet<string> _selectedRouteIds = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _seenRealtimeMessageIds = new(StringComparer.OrdinalIgnoreCase);
    private readonly Queue<string> _seenRealtimeMessageOrder = new();
    private string? _historyCursor;
    private string _activeFilter=string.Empty;
    private const int MessagePageSize = 50;

    public ShellViewModel(DispatcherQueue dispatcher, IMicaGoApi api, AppServices services)
    {
        _dispatcher = dispatcher; _api = api; _services = services;
    }

    public ChatListCollection Chats { get; } = [];
    public ObservableCollection<MessageRow> Messages { get; } = [];
    public ChatSummary? SelectedChat { get; private set; }
    public string SyncStatus { get; private set; } = "Cached";
    public bool IsLoadingOlder { get; private set; }
    public bool HasMoreMessages { get; private set; }
    public int HiddenChatCount => _allChats.Count(IsChatHidden);
    public int HiddenMessageCount => _hiddenMessageKeys.Count;
    public IReadOnlyList<ChatSummary> HiddenChats => _allChats.Where(IsChatHidden).OrderByDescending(chat=>chat.UpdatedAt).ToArray();
    public MessageActionCapabilities ActionCapabilities { get; private set; }=new(false,false,false);

    public event EventHandler? StateChanged;
    public event EventHandler? RealtimeChanged;

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        await _services.Cache.InitializeAsync(cancellationToken);
        _hiddenMessageKeys = await _services.Cache.GetHiddenMessageKeysAsync(cancellationToken);
        _hiddenChatGuids = await _services.Cache.GetHiddenChatGuidsAsync(cancellationToken);
        var cached = await _services.Cache.GetChatsAsync(cancellationToken);
        ApplyChatSnapshot(await ApplyContactNamesAsync(cached, cancellationToken));
        try
        {
            var remote = await _api.GetChatsAsync(cancellationToken);
            await _services.Cache.UpsertChatsAsync(remote, cancellationToken);
            ApplyChatSnapshot(await ApplyContactNamesAsync(remote, cancellationToken));
        }
        catch when (cached.Count > 0) { SyncStatus = "Offline cache"; }
        try{ActionCapabilities=await _api.GetMessageActionCapabilitiesAsync(cancellationToken);}catch{ActionCapabilities=new(false,false,false);}

        _realtime = new RealtimeSyncService(_api, _services.Cache);
        _realtime.MessagesChanged += OnRealtimeMessagesChanged;
        _realtime.StatusChanged += (_, status) => Dispatch(() => { SyncStatus = status; StateChanged?.Invoke(this, EventArgs.Empty); });
        _realtime.Start();
    }

    public void ApplyFilter(string query)
    {
        _activeFilter=query;
        ApplyVisibleChats(false);
    }

    public void RefreshChatTimestamps()
    {
        foreach(var chat in _allChats)chat.UpdateFrom(chat with{Time=ChatTimestamp(chat.UpdatedAt)});
    }

    public string FormatActivityTimestamp(long milliseconds) => ChatTimestamp(milliseconds);

    public async Task RefreshContactsAsync(CancellationToken cancellationToken=default)
    {
        ApplyChatSnapshot(await ApplyContactNamesAsync(await _services.Cache.GetChatsAsync(cancellationToken),cancellationToken));
        if(SelectedChat is not{} selected)return;
        var updated=_allChats.FirstOrDefault(chat=>chat.ListKey==selected.ListKey||MatchesRoute(chat,selected.Id));if(updated is not null)SelectedChat=updated;
        ApplyMessages(await DecorateMessageSendersAsync(_rawMessages,SelectedChat?.IsGroup==true,cancellationToken));
    }

    public async Task HideChatAsync(ChatSummary chat,CancellationToken cancellationToken=default)
    {
        var routes=chat.RouteIds is{Count:>0}?chat.RouteIds:[chat.Id];
        await _services.Cache.HideChatsAsync(routes,cancellationToken);
        _hiddenChatGuids=new HashSet<string>(_hiddenChatGuids.Concat(routes),StringComparer.OrdinalIgnoreCase);
        if(SelectedChat is{} selected&&(selected.Id==chat.Id||routes.Contains(selected.Id)||selected.RouteIds?.Any(routes.Contains)==true))
        {
            SelectedChat=null;_selectedRouteIds.Clear();_rawMessages=[];SyncMessages([]);
        }
        ApplyVisibleChats(false);StateChanged?.Invoke(this,EventArgs.Empty);
    }

    public async Task<int> RestoreHiddenChatsAsync(IEnumerable<string> chatIds,CancellationToken cancellationToken=default)
    {
        var requested=chatIds.ToHashSet(StringComparer.OrdinalIgnoreCase);
        var routes=_allChats.Where(chat=>requested.Contains(chat.Id)).SelectMany(chat=>chat.RouteIds is{Count:>0}?chat.RouteIds:[chat.Id]).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        var restored=await _services.Cache.RestoreHiddenChatsAsync(routes,cancellationToken);
        _hiddenChatGuids=new HashSet<string>(_hiddenChatGuids.Except(routes,StringComparer.OrdinalIgnoreCase),StringComparer.OrdinalIgnoreCase);
        ApplyVisibleChats(false);StateChanged?.Invoke(this,EventArgs.Empty);return restored;
    }

    public Task<IReadOnlyList<Message>> GetHiddenMessagesAsync(CancellationToken cancellationToken=default)=>_services.Cache.GetHiddenMessagesAsync(cancellationToken);
    public async Task<int> RestoreHiddenMessagesAsync(IEnumerable<string> messageIds,CancellationToken cancellationToken=default)
    {
        var restored=await _services.Cache.RestoreHiddenMessagesAsync(messageIds,cancellationToken);
        _hiddenMessageKeys=await _services.Cache.GetHiddenMessageKeysAsync(cancellationToken);
        ApplyMessages(_rawMessages);return restored;
    }

    public async Task SelectChatAsync(ChatSummary chat, CancellationToken cancellationToken = default)
    {
        _selectionCts?.Cancel(); _selectionCts?.Dispose(); _selectionCts=CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);var token=_selectionCts.Token;
        var routes=chat.RouteIds is{Count:>0}?chat.RouteIds:[chat.Id];
        var nextRouteIds=routes.ToHashSet(StringComparer.OrdinalIgnoreCase);
        if(!_selectedRouteIds.SetEquals(nextRouteIds))
        {
            // A loaded snapshot may only merge with live/pending rows from the
            // same conversation. Keeping the previous thread here accumulated
            // A + B + C because MergeSnapshot correctly treats different
            // (ChatId, Id) pairs as distinct messages.
            _selectedRouteIds=nextRouteIds;
            _rawMessages=[];
            SyncMessages([]);
        }
        SelectedChat = chat;
        _historyCursor=null;
        // C74: the whole body is guarded. The first cache read and its
        // ThrowIfCancellationRequested used to sit OUTSIDE the try, so clicking
        // two conversations quickly threw OperationCanceledException straight
        // into `async void ChatList_ItemClick` — an unhandled WinUI exception.
        var cached = Array.Empty<Message>();
        try
        {
            cached=OrderTimeline((await Task.WhenAll(routes.Select(route=>_services.Cache.GetMessagesAsync(route,MessagePageSize,cancellationToken:token)))).SelectMany(row=>row)).TakeLast(MessagePageSize).ToArray();
            token.ThrowIfCancellationRequested(); if(SelectedChat?.ListKey!=chat.ListKey)return;
            MergeSnapshotMessages(await DecorateMessageSendersAsync(cached,chat.IsGroup,token));
            await RestorePendingUploadsAsync(chat.PrimaryRouteId,token);

            var remote=await _api.GetMessageHistoryAsync(routes,MessagePageSize,cancellationToken:token);
            await _services.Cache.UpsertMessagesAsync(remote.Messages, token);
            token.ThrowIfCancellationRequested(); if(SelectedChat?.ListKey!=chat.ListKey)return;
            MergeSnapshotMessages(await DecorateMessageSendersAsync(remote.Messages,chat.IsGroup,token));
            await RestorePendingUploadsAsync(chat.PrimaryRouteId,token);
            _historyCursor=remote.NextCursor;
            HasMoreMessages=remote.HasMore;
        }
        catch (OperationCanceledException){return;}
        catch when (cached.Length > 0) { HasMoreMessages=cached.Length==MessagePageSize; }
        try { await MarkSelectedChatReadAsync(chat,token); }
        catch (OperationCanceledException){return;}
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    public async Task LoadOlderMessagesAsync(CancellationToken cancellationToken=default)
    {
        if(SelectedChat is not{} chat||IsLoadingOlder||!HasMoreMessages)return;IsLoadingOlder=true;StateChanged?.Invoke(this,EventArgs.Empty);
        using var linked=CancellationTokenSource.CreateLinkedTokenSource(cancellationToken,_selectionCts?.Token??CancellationToken.None);var token=linked.Token;
        try
        {
            var routes=chat.RouteIds is{Count:>0}?chat.RouteIds:[chat.Id];
            var page=await _api.GetMessageHistoryAsync(routes,MessagePageSize,_historyCursor,token);
            await _services.Cache.UpsertMessagesAsync(page.Messages,token);
            if(SelectedChat?.ListKey!=chat.ListKey)return;
            _historyCursor=page.NextCursor;
            HasMoreMessages=page.HasMore;
            MergeSnapshotMessages(await DecorateMessageSendersAsync(page.Messages.Concat(_rawMessages),chat.IsGroup,token));
        }
        catch(OperationCanceledException)when(token.IsCancellationRequested){}
        finally{IsLoadingOlder=false;StateChanged?.Invoke(this,EventArgs.Empty);}
    }

    private async Task MarkSelectedChatReadAsync(ChatSummary chat,CancellationToken token)
    {
        foreach(var route in chat.RouteIds is{Count:>0} routes?routes:[chat.Id])
        {
            var latest=_rawMessages.Where(row=>row.ChatId.Equals(route,StringComparison.OrdinalIgnoreCase)).Select(row=>row.DateCreated).DefaultIfEmpty(0).Max();
            if(latest>0)await _services.Cache.SetSettingAsync("read.watermark."+route,latest.ToString(),token);
        }
        var current=_allChats.FirstOrDefault(item=>item.ListKey==chat.ListKey);if(current is null)return;current.UpdateFrom(current with{UnreadCount=0,HasUnread=false});SelectedChat=current;ApplyVisibleChats(false);
    }

    public async Task SendTextAsync(string text, CancellationToken cancellationToken = default)
    {
        if (SelectedChat is null || string.IsNullOrWhiteSpace(text)) return;
        var tempId = "local-" + Guid.NewGuid().ToString("N");
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var route = SelectedChat.PrimaryRouteId;
        var pending = new Message(tempId, route, text.Trim(), DateTime.Now.ToString("HH:mm"), true, MessageDeliveryState.Sending, DateCreated: now, IsPending: true, PresentationId: tempId);
        ApplyMessages(_rawMessages.Append(pending),new Dictionary<string,MessageEntranceKind>{{pending.TimelineKey,MessageEntranceKind.LocalSend}});
        try
        {
            var confirmed = await _api.SendTextAsync(route, text.Trim(), tempId, cancellationToken);
            var index = _rawMessages.FindIndex(item=>item.PresentationKey==pending.PresentationKey); if (index >= 0){var raw=_rawMessages.ToList();raw[index]=MessageSemantics.ReconcilePresentation(raw[index],confirmed);ApplyMessages(raw);}
            await _services.Cache.UpsertMessagesAsync([confirmed], cancellationToken);
        }
        catch (MicaGoApiException exception) when (exception.Code=="send_confirmation_timeout"||exception.StatusCode==202)
        {
            // Same optimistic row, same presentation key: only the footer moves
            // from Sending to Sent while send:match/delta remains authoritative.
            var index=_rawMessages.FindIndex(item=>item.PresentationKey==pending.PresentationKey);
            if(index>=0&&_rawMessages[index].IsPending){var raw=_rawMessages.ToList();raw[index]=raw[index] with{DeliveryState=MessageDeliveryState.Sent,ErrorText=null};ApplyMessages(raw);}
        }
        catch (Exception exception)
        {
            var index = _rawMessages.FindIndex(item=>item.PresentationKey==pending.PresentationKey); if (index >= 0&&_rawMessages[index].IsPending){var raw=_rawMessages.ToList();raw[index]=raw[index] with { DeliveryState = MessageDeliveryState.Failed, ErrorText = exception.Message };ApplyMessages(raw);}
        }
    }

    public async Task SendAttachmentsAsync(IEnumerable<string> filePaths, bool isAudioMessage = false, CancellationToken cancellationToken = default)
    {
        if (SelectedChat is null) return;
        var staged = filePaths.Select((filePath, index) =>
        {
            var tempId = "local-" + Guid.NewGuid().ToString("N");
            var fileName = Path.GetFileName(filePath); var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + index;
            var attachment = new Attachment(tempId, fileName, MimeFor(filePath), new FileInfo(filePath).Length);
            var route = SelectedChat.PrimaryRouteId;
            var pending = new Message(tempId, route, string.Empty, DateTime.Now.ToString("HH:mm"), true, MessageDeliveryState.Sending, AttachmentLabel: fileName, DateCreated: now, Attachments: [attachment], IsPending: true, PresentationId: tempId);
            _pendingAttachmentPaths[tempId] = filePath;
            _= _services.Cache.UpsertPendingUploadAsync(new PendingUpload(tempId,route,filePath,fileName,attachment.MimeType,attachment.Size,now),cancellationToken);
            return (filePath, tempId, pending);
        }).ToArray();
        ApplyMessages(_rawMessages.Concat(staged.Select(item=>item.pending)),staged.ToDictionary(item=>item.pending.TimelineKey,_=>MessageEntranceKind.LocalSend,StringComparer.OrdinalIgnoreCase));
        foreach (var item in staged)
        {
            await _services.Media.SeedAsync(item.tempId, item.filePath, cancellationToken);
            try { await UploadAttachmentAsync(item.pending, item.filePath, cancellationToken, isAudioMessage);var index=_rawMessages.FindIndex(row=>row.PresentationKey==item.pending.PresentationKey);if(index>=0&&_rawMessages[index].IsPending){var raw=_rawMessages.ToList();raw[index]=raw[index] with{DeliveryState=MessageDeliveryState.Sent,UploadProgress=1};ApplyMessages(raw);}await _services.Cache.UpsertPendingUploadAsync(new PendingUpload(item.tempId,item.pending.ChatId,item.filePath,item.pending.AttachmentLabel??Path.GetFileName(item.filePath),item.pending.Media[0].MimeType,item.pending.Media[0].Size,item.pending.DateCreated,"sent_unconfirmed"),cancellationToken); }
            catch (Exception exception) { var index = _rawMessages.FindIndex(row=>row.PresentationKey==item.pending.PresentationKey); if (index >= 0&&_rawMessages[index].IsPending){var raw=_rawMessages.ToList();raw[index]=raw[index] with { DeliveryState = MessageDeliveryState.Failed, ErrorText = exception.Message };ApplyMessages(raw);}await _services.Cache.UpsertPendingUploadAsync(new PendingUpload(item.tempId,item.pending.ChatId,item.filePath,item.pending.AttachmentLabel??Path.GetFileName(item.filePath),item.pending.Media[0].MimeType,item.pending.Media[0].Size,item.pending.DateCreated,"failed",exception.Message),cancellationToken); }
        }
    }

    public async Task EditAsync(Message message, string text, CancellationToken cancellationToken = default) { await _api.EditMessageAsync(message.ChatId, message.Id, text, cancellationToken: cancellationToken); if (_realtime is not null) await _realtime.CatchUpAsync(cancellationToken); }
    public async Task RetractAsync(Message message, CancellationToken cancellationToken = default) { await _api.RetractMessageAsync(message.ChatId, message.Id, cancellationToken: cancellationToken); if (_realtime is not null) await _realtime.CatchUpAsync(cancellationToken); }
    public async Task DeleteAsync(Message message, CancellationToken cancellationToken = default) { if(!message.IsPending)await _api.DeleteMessageAsync(message.ChatId, message.Id, cancellationToken);ApplyMessages(_rawMessages.Where(item=>item.TimelineKey!=message.TimelineKey));_pendingAttachmentPaths.Remove(message.PresentationKey);await _services.Cache.DeletePendingUploadAsync(message.PresentationKey,cancellationToken);if(!message.IsPending)await _services.Cache.DeleteMessageAsync(message.ChatId,message.Id, cancellationToken); }
    public async Task RetryAttachmentAsync(Message message, CancellationToken cancellationToken = default)
    {
        if (!_pendingAttachmentPaths.TryGetValue(message.PresentationKey, out var path) || !File.Exists(path)) return;
        var index=_rawMessages.FindIndex(item=>item.PresentationKey==message.PresentationKey); if(index<0)return; var sending=message with { DeliveryState=MessageDeliveryState.Sending, ErrorText=null, UploadProgress=0 };var raw=_rawMessages.ToList();raw[index]=sending;ApplyMessages(raw);
        await _services.Cache.UpsertPendingUploadAsync(new PendingUpload(sending.Id,sending.ChatId,path,sending.AttachmentLabel??Path.GetFileName(path),sending.Media[0].MimeType,sending.Media[0].Size,sending.DateCreated),cancellationToken);
        try{await UploadAttachmentAsync(sending,path,cancellationToken);index=_rawMessages.FindIndex(item=>item.PresentationKey==sending.PresentationKey);if(index>=0&&_rawMessages[index].IsPending){raw=_rawMessages.ToList();raw[index]=raw[index] with{DeliveryState=MessageDeliveryState.Sent,UploadProgress=1};ApplyMessages(raw);}await _services.Cache.UpsertPendingUploadAsync(new PendingUpload(sending.Id,sending.ChatId,path,sending.AttachmentLabel??Path.GetFileName(path),sending.Media[0].MimeType,sending.Media[0].Size,sending.DateCreated,"sent_unconfirmed"),cancellationToken);}
        catch(Exception exception){index=_rawMessages.FindIndex(item=>item.PresentationKey==sending.PresentationKey);if(index>=0&&_rawMessages[index].IsPending){raw=_rawMessages.ToList();raw[index]=raw[index] with{DeliveryState=MessageDeliveryState.Failed,ErrorText=exception.Message};ApplyMessages(raw);}await _services.Cache.UpsertPendingUploadAsync(new PendingUpload(sending.Id,sending.ChatId,path,sending.AttachmentLabel??Path.GetFileName(path),sending.Media[0].MimeType,sending.Media[0].Size,sending.DateCreated,"failed",exception.Message),cancellationToken);}
    }
    public void CancelAttachmentUpload(Message message){if(_uploadCancellations.TryGetValue(message.PresentationKey,out var cancellation))cancellation.Cancel();}

    /// <summary>Hides messages locally (tombstone table — a server re-sync cannot resurrect them).</summary>
    public async Task HideMessagesAsync(IEnumerable<Message> messages, CancellationToken cancellationToken = default)
    {
        var ids = messages.Where(row => !row.IsSeparator && !row.IsPending).Select(row => row.TimelineKey).ToArray();
        if (ids.Length == 0) return;
        await _services.Cache.HideMessagesAsync(ids, cancellationToken);
        _hiddenMessageKeys = await _services.Cache.GetHiddenMessageKeysAsync(cancellationToken);
        ApplyMessages(_rawMessages);
    }

    /// <summary>
    /// Forwards messages to another chat in chronological order: visible text
    /// is re-sent as text; attachments are staged from the media cache under
    /// their original file name and re-uploaded.
    /// </summary>
    public async Task ForwardMessagesAsync(ChatSummary target, IReadOnlyList<Message> messages, CancellationToken cancellationToken = default)
    {
        foreach (var message in messages.Where(row => !row.IsSeparator && !row.IsPresentationSystem).OrderBy(row => row.DateCreated))
        {
            var text = MessageSemantics.VisibleText(message.Text);
            if (text.Length > 0)
            {
                try { await _api.SendTextAsync(target.Id, text, "local-" + Guid.NewGuid().ToString("N"), cancellationToken); }
                catch { }
            }
            foreach (var attachment in message.Media.Where(item => !item.Id.StartsWith("local-", StringComparison.Ordinal)))
            {
                try
                {
                    var cachedPath = _services.Media.TryGetPath(attachment.Id)
                        ?? await _services.Media.GetAsync(_api, attachment.Id, cancellationToken: cancellationToken);
                    var staging = Path.Combine(Path.GetTempPath(), "micaGO-forward", Guid.NewGuid().ToString("N"));
                    Directory.CreateDirectory(staging);
                    var named = Path.Combine(staging, string.IsNullOrWhiteSpace(attachment.FileName) ? "attachment" : attachment.FileName);
                    File.Copy(cachedPath, named, true);
                    try { await _api.SendAttachmentAsync(target.Id, "local-" + Guid.NewGuid().ToString("N"), named, cancellationToken: cancellationToken); }
                    finally { try { Directory.Delete(staging, true); } catch { } }
                }
                catch { }
            }
        }
        if (_realtime is not null) await _realtime.CatchUpAsync(cancellationToken);
    }

    /// <summary>Re-fetches the chat list (used after toggling the offline test contact).</summary>
    public async Task ReloadChatsAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            var remote = await _api.GetChatsAsync(cancellationToken);
            await _services.Cache.UpsertChatsAsync(remote, cancellationToken);
            ApplyChatSnapshot(await ApplyContactNamesAsync(remote, cancellationToken));
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
        catch { }
    }

    private async Task UploadAttachmentAsync(Message pending,string path,CancellationToken cancellationToken,bool isAudioMessage=false)
    {
        var uploadCancellation=CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);_uploadCancellations[pending.PresentationKey]=uploadCancellation;
        var progress=new Progress<double>(value=>
        {
            var row=Messages.FirstOrDefault(item=>item.PresentationKey==pending.PresentationKey);if(row is null)return;
            var rawIndex=_rawMessages.FindIndex(item=>item.PresentationKey==pending.PresentationKey);
            if(rawIndex>=0)_rawMessages[rawIndex]=_rawMessages[rawIndex] with{UploadProgress=value};
            row.Update(row.Value with{UploadProgress=value});
        });
        try{await _api.SendAttachmentAsync(pending.ChatId,pending.Id,path,isAudioMessage:isAudioMessage,progress:progress,cancellationToken:uploadCancellation.Token);}
        finally{_uploadCancellations.Remove(pending.PresentationKey);uploadCancellation.Dispose();}
    }

    private async void OnRealtimeMessagesChanged(object? sender, RealtimeMessageBatch batch)
    {
        var changed=batch.Messages;
        var selected=SelectedChat;var decorated=selected is null?changed:await DecorateMessageSendersAsync(changed,selected.IsGroup,CancellationToken.None);
        Dispatch(() =>
        {
            var raw = _rawMessages.ToList();
            var selectedMessagesChanged = false;
            var entrances=new Dictionary<string,MessageEntranceKind>(StringComparer.OrdinalIgnoreCase);
            foreach (var message in decorated)
            {
                var isSelected=SelectedChat is{} selected&&(selected.Id==message.ChatId||(selected.RouteIds?.Contains(message.ChatId)??false));
                if(isSelected)
                {
                    // C74: the open conversation is the authority on "seen". The
                    // watermark used to advance only at selection time, so a
                    // message arriving while you read it left the watermark
                    // behind — and the next chat-list rebuild (which derives
                    // HasUnread from the watermark) relit the dot on the chat
                    // you were looking at.
                    AdvanceReadWatermark(message);
                    var existing = raw.FirstOrDefault(item => item.ChatId.Equals(message.ChatId,StringComparison.OrdinalIgnoreCase) && item.Id == message.Id);
                    if (existing is not null)
                    {
                        var updated = MessageSemantics.ReconcilePresentation(existing, message);
                        if (!existing.Equals(updated)) { raw[raw.IndexOf(existing)] = updated; selectedMessagesChanged = true; }
                    }
                    else
                    {
                        // send:match carries the exact tempGuid, just like Flutter's
                        // confirmPending(tempId, server). Delta-only rows fall back
                        // to the conservative one-to-one semantic matcher.
                        var pending = !string.IsNullOrWhiteSpace(message.PresentationId)
                            ? raw.FirstOrDefault(item=>item.IsPending&&item.ChatId.Equals(message.ChatId,StringComparison.OrdinalIgnoreCase)&&item.PresentationKey==message.PresentationId)
                            : MessageSemantics.MatchingPending(raw, message);
                        if (pending is not null){var index=raw.IndexOf(pending);raw[index]=MessageSemantics.ReconcilePresentation(pending,message);_pendingAttachmentPaths.Remove(pending.PresentationKey);_=_services.Cache.DeletePendingUploadAsync(pending.PresentationKey);}
                        else
                        {
                            raw.Add(message);
                            if(CanAnimateNewMessage(message))entrances[message.TimelineKey]=MessageEntranceKind.Realtime;
                        }
                        selectedMessagesChanged = true;
                    }
                }
            }
            if (selectedMessagesChanged) ApplyMessages(raw,entrances);
            var needsChatReload = UpdateChatsForMessages(decorated,batch.AllowNotifications);
            RealtimeChanged?.Invoke(this, EventArgs.Empty);
            if(needsChatReload)_=ReloadChatsAsync();
        });
    }

    private bool UpdateChatsForMessages(IEnumerable<Message> messages,bool allowNotifications)
    {
        var updates = new Dictionary<string,ChatSummary>(StringComparer.OrdinalIgnoreCase);
        var needsReload = false;
        foreach (var message in messages)
        {
            var canonical=_allChats.FirstOrDefault(chat=>MatchesRoute(chat,message.ChatId));
            if(canonical is null)
            {
                // A first message can arrive before the chats endpoint exposes
                // its new row. Seed initial-history ids even while notifications
                // are suppressed, then notify a genuinely new unknown route once.
                var unknownRouteFirstObservation=RememberRealtimeMessage(message.ChatId,message.Id);
                needsReload=true;
                if(allowNotifications&&unknownRouteFirstObservation&&!message.IsOutgoing)
                {
                    var title=string.IsNullOrWhiteSpace(message.SenderName)?_services.Localization["newMessage"]:message.SenderName;
                    _services.Notifications.Show(title,MessageSemantics.PreviewText(message),message.ChatId);
                }
                continue;
            }
            var chat=updates.GetValueOrDefault(canonical.ListKey,canonical);
            var isSelected=SelectedChat is{} selected&&MatchesRoute(selected,message.ChatId);
            var firstObservation = RememberRealtimeMessage(message.ChatId,message.Id);
            var advancesChat = message.DateCreated > chat.UpdatedAt;
            var updatesLatest = message.DateCreated >= chat.UpdatedAt;
            var incomingUnseen=firstObservation&&advancesChat&&!message.IsOutgoing&&!isSelected;
            var preview=MessageSemantics.PreviewText(message);
            updates[canonical.ListKey]=chat with
            {
                Preview=updatesLatest?preview:chat.Preview,
                Time=updatesLatest?message.SentAt:chat.Time,
                UpdatedAt=Math.Max(chat.UpdatedAt,message.DateCreated),
                UnreadCount=isSelected?0:incomingUnseen?chat.UnreadCount+1:chat.UnreadCount,
                HasUnread=!isSelected&&(incomingUnseen||chat.HasUnread),
                LatestFromMe=updatesLatest?message.IsOutgoing:chat.LatestFromMe,
            };
            if(allowNotifications&&incomingUnseen&&!chat.IsMuted)_services.Notifications.Show(chat.Title,preview,message.ChatId);
        }
        if (updates.Count==0) return needsReload;
        foreach(var (key,updated) in updates)
        {
            var canonical=_allChats.First(chat=>chat.ListKey.Equals(key,StringComparison.OrdinalIgnoreCase));
            canonical.UpdateFrom(updated);
        }
        _allChats=_allChats.OrderByDescending(item=>item.IsPinned).ThenByDescending(item=>item.UpdatedAt).ToList();
        ApplyVisibleChats(true);
        return needsReload;
    }

    /// <summary>Moves the per-route read watermark past a message observed while
    /// its conversation is open (fire-and-forget: the dot is derived state).</summary>
    private void AdvanceReadWatermark(Message message)
    {
        if (SelectedChat is not { } selected) return;
        if(!MatchesRoute(selected,message.ChatId)||message.DateCreated<=0)return;
        _ = _services.Cache.SetSettingAsync("read.watermark." + message.ChatId, message.DateCreated.ToString());
    }

    private bool RememberRealtimeMessage(string chatId,string id)
    {
        var key=string.Concat(chatId,"\u001f",id);
        if (!_seenRealtimeMessageIds.Add(key)) return false;
        _seenRealtimeMessageOrder.Enqueue(key);
        while (_seenRealtimeMessageOrder.Count > 2048)
            _seenRealtimeMessageIds.Remove(_seenRealtimeMessageOrder.Dequeue());
        return true;
    }

    private void ApplyChatSnapshot(IEnumerable<ChatSummary> rows)
    {
        // C74: the server does not carry UnreadCount, so a plain assignment
        // zeroed the badge on every chat refresh while HasUnread stayed true
        // (derived from the watermark) — the number flickered off and on.
        // Carry the locally tracked count across unless the row reads as seen.
        var previous = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        foreach (var chat in _allChats) previous[chat.ListKey] = chat.UnreadCount;
        var incoming=rows
            .Select(chat => chat.UnreadCount == 0
                && chat.HasUnread
                && previous.TryGetValue(chat.ListKey, out var carried)
                && carried > 0
                    ? chat with { UnreadCount = carried }
                    : chat)
            .ToArray();
        var existing=_allChats.ToDictionary(chat=>chat.ListKey,StringComparer.OrdinalIgnoreCase);
        var canonical=new List<ChatSummary>(incoming.Length);
        foreach(var row in incoming)
        {
            if(existing.TryGetValue(row.ListKey,out var current)){current.UpdateFrom(row);canonical.Add(current);}
            else canonical.Add(row);
        }
        _allChats=canonical;
        if(SelectedChat is{} selected)
        {
            var updated=_allChats.FirstOrDefault(chat=>chat.ListKey==selected.ListKey||MatchesRoute(chat,selected.Id));
            if(updated is not null)SelectedChat=updated;
        }
        ApplyVisibleChats(false);
    }

    private bool IsChatHidden(ChatSummary chat)
    {
        if(_hiddenChatGuids.Contains(chat.Id))return true;
        return chat.RouteIds?.Any(_hiddenChatGuids.Contains)==true;
    }

    private bool IsChatVisible(ChatSummary chat) => !IsChatHidden(chat)
        && (string.IsNullOrWhiteSpace(_activeFilter)
            || chat.Title.Contains(_activeFilter,StringComparison.CurrentCultureIgnoreCase)
            || chat.Preview.Contains(_activeFilter,StringComparison.CurrentCultureIgnoreCase));

    private void ApplyVisibleChats(bool animateMoves) =>
        Chats.Apply(_allChats.Where(IsChatVisible).ToArray(), animateMoves);

    private static bool MatchesRoute(ChatSummary chat,string route) =>
        chat.Id.Equals(route,StringComparison.OrdinalIgnoreCase)
        || chat.PrimaryRouteId.Equals(route,StringComparison.OrdinalIgnoreCase)
        || chat.RouteIds?.Contains(route,StringComparer.OrdinalIgnoreCase)==true;
    private async Task<IReadOnlyList<ChatSummary>> ApplyContactNamesAsync(IReadOnlyList<ChatSummary> rows, CancellationToken cancellationToken)
    {
        var result = new List<ChatSummary>(rows.Count);
        foreach (var chat in rows)
        {
            var locallyMuted=await _services.Cache.GetSettingAsync("chat.muted."+chat.Id,cancellationToken)=="1";var locallyPinned=await _services.Cache.GetSettingAsync("chat.pinned."+chat.Id,cancellationToken)=="1";
            // C43-style derived unread: the dot survives restarts because it is
            // computed from the read watermark, never from a live counter.
            var watermarkRaw=await _services.Cache.GetSettingAsync("read.watermark."+chat.Id,cancellationToken);
            long.TryParse(watermarkRaw,out var watermark);
            var hasUnread=!chat.LatestFromMe&&chat.UpdatedAt>0&&chat.UpdatedAt>watermark;
            var decorated=chat with{IsMuted=chat.IsMuted||locallyMuted,IsPinned=chat.IsPinned||locallyPinned,HasUnread=hasUnread};
            if (chat.IsGroup || chat.Participants is not { Count: > 0 }) { result.Add(decorated); continue; }
            var contact = await _services.Cache.ResolveContactAsync(chat.Participants[0], cancellationToken);
            if (contact is null) { result.Add(decorated); continue; }
            var initials = string.Concat(contact.DisplayName.Split(' ', StringSplitOptions.RemoveEmptyEntries).Take(2).Select(part => char.ToUpperInvariant(part[0])));
            var conversationKey="contact:"+contact.ContactId.ToUpperInvariant();
            var contactMuted=await _services.Cache.GetSettingAsync("chat.muted."+conversationKey,cancellationToken)=="1";
            var contactPinned=await _services.Cache.GetSettingAsync("chat.pinned."+conversationKey,cancellationToken)=="1";
            result.Add(decorated with { Title = contact.DisplayName, Initials = string.IsNullOrWhiteSpace(initials) ? chat.Initials : initials, AvatarPath=contact.AvatarPath,RouteIds=[chat.Id],PrimaryRouteId=chat.Id,ContactId=contact.ContactId,IsMuted=decorated.IsMuted||contactMuted,IsPinned=decorated.IsPinned||contactPinned });
        }
        var merged=new List<ChatSummary>();
        foreach(var group in result.GroupBy(chat=>!chat.IsGroup&&!string.IsNullOrWhiteSpace(chat.ContactId)?"contact:"+chat.ContactId:"route:"+chat.Id,StringComparer.OrdinalIgnoreCase))
        {
            var routes=group.OrderByDescending(chat=>chat.UpdatedAt).ToArray();var primary=routes[0];
            var mergeKey="chat.mergeRoutes."+(primary.ContactId??primary.Id);
            var mergeAllowed=routes.Length>1&&await _services.Cache.GetSettingAsync(mergeKey,cancellationToken)!="0";
            if(routes.Length>1&&!mergeAllowed){merged.AddRange(routes);continue;}
            var savedRoute=await _services.Cache.GetSettingAsync("chat.sendRoute."+(primary.ContactId??primary.Id),cancellationToken);
            var sendRoute=routes.FirstOrDefault(route=>route.Id.Equals(savedRoute,StringComparison.OrdinalIgnoreCase))
                ?? routes.FirstOrDefault(route=>route.ServiceLabel.Equals("iMessage",StringComparison.OrdinalIgnoreCase)&&route.CanSendText)
                ?? routes.FirstOrDefault(route=>route.CanSendText)
                ?? primary;
            merged.Add(routes.Length>1?primary with{RouteIds=routes.Select(route=>route.Id).ToArray(),PrimaryRouteId=sendRoute.Id,Preview=primary.Preview,HasUnread=routes.Any(route=>route.HasUnread)}:primary);
        }
        return merged.OrderByDescending(chat=>chat.IsPinned).ThenByDescending(chat=>chat.UpdatedAt).Select(chat=>chat with{Time=ChatTimestamp(chat.UpdatedAt)}).ToArray();
    }
    private string ChatTimestamp(long milliseconds)
    {
        if(milliseconds<=0)return string.Empty;var value=DateTimeOffset.FromUnixTimeMilliseconds(milliseconds).LocalDateTime;var now=DateTime.Now;var difference=now-value;var language=_services.Localization.Language;
        if(difference.TotalMinutes<1)return language=="zh-Hant"?"剛剛":language=="zh-Hans"?"刚刚":"now";
        if(difference.TotalMinutes<60){var minutes=Math.Max(1,(int)difference.TotalMinutes);return language=="zh-Hant"?$"{minutes} 分鐘前":language=="zh-Hans"?$"{minutes} 分钟前":$"{minutes}m";}
        var days=(now.Date-value.Date).Days;if(days<=0)return value.ToString("t");if(days==1)return language.StartsWith("zh",StringComparison.Ordinal)?"昨天":"Yesterday";if(days<7)return value.ToString("dddd");return value.ToString("d");
    }
    private async Task<IReadOnlyList<Message>> DecorateMessageSendersAsync(IEnumerable<Message> rows,bool isGroup,CancellationToken token)
    {
        var result=rows.ToArray();if(!isGroup)return result;
        var contacts=new Dictionary<string,ContactMatch?>(StringComparer.OrdinalIgnoreCase);
        for(var i=0;i<result.Length;i++)
        {
            var row=result[i];if(row.IsOutgoing)continue;var identity=(row.SenderIdentity??row.SenderName)?.Trim();if(string.IsNullOrWhiteSpace(identity))continue;
            if(!contacts.TryGetValue(identity,out var contact)){contact=await _services.Cache.ResolveContactAsync(identity,token);contacts[identity]=contact;}
            result[i]=row with{SenderIdentity=identity,SenderName=contact?.DisplayName??identity,SenderAvatarPath=contact?.AvatarPath};
        }
        return result;
    }
    private void MergeSnapshotMessages(IEnumerable<Message> rows) => SetMessages(rows, mergeSnapshot: true);
    private void ApplyMessages(IEnumerable<Message> rows,IReadOnlyDictionary<string,MessageEntranceKind>? entrances=null) => SetMessages(rows, mergeSnapshot: false,entrances);

    private static bool CanAnimateNewMessage(Message message) => !message.IsReaction
        && !message.IsServiceEvent
        && !message.IsRetracted
        && (MessageSemantics.VisibleText(message.Text).Length>0||message.Media.Count>0);

    /// <summary>
    /// Rebuilds the visible timeline from <paramref name="rows"/>. The merge
    /// itself lives in MessageSemantics.MergeSnapshot (pure + contract-tested):
    /// a late snapshot must not wipe rows that arrived live while it loaded.
    /// </summary>
    private void SetMessages(IEnumerable<Message> rows, bool mergeSnapshot,IReadOnlyDictionary<string,MessageEntranceKind>? entrances=null)
    {
        var scopedRows=rows.Where(row=>!row.IsSeparator&&_selectedRouteIds.Contains(row.ChatId)).ToArray();
        _rawMessages = mergeSnapshot
            ? MessageSemantics.MergeSnapshot(_rawMessages,scopedRows,_selectedRouteIds).ToList()
            : OrderTimeline(scopedRows).ToList();
        var visible=_hiddenMessageKeys.Count==0?_rawMessages:_rawMessages.Where(row=>!_hiddenMessageKeys.Contains(row.TimelineKey)&&!_hiddenMessageKeys.Contains(row.Id)).ToList();
        SyncMessages(ThreadPresentation.Build(visible,SelectedChat?.IsGroup==true,_services.Localization.Language),entrances);
    }

    /// <summary>
    /// Applies the freshly built presentation list to the bound collection as a
    /// stable keyed diff (update in place / insert / trim) instead of
    /// Clear()+Add(): a full reset makes the ListView drop its scroll position,
    /// which is why sending a message used to jump the thread to the top.
    /// </summary>
    private void SyncMessages(IReadOnlyList<Message> target,IReadOnlyDictionary<string,MessageEntranceKind>? entrances=null)
    {
        var inserted = 0;
        var updated = 0;
        var removed = 0;
        var targetKeys = new HashSet<string>(target.Select(row => row.TimelineKey),StringComparer.OrdinalIgnoreCase);
        for (var i = Messages.Count - 1; i >= 0; i--)
        {
            if (!targetKeys.Contains(Messages[i].Value.TimelineKey)) { Messages.RemoveAt(i); removed++; }
        }

        // Resolve identities once. The previous nested scan made one refresh
        // quadratic and amplified rapid-send layout pressure even when only a
        // footer and its neighboring row had changed.
        var existingByKey=Messages.ToDictionary(row=>row.Value.TimelineKey,StringComparer.OrdinalIgnoreCase);

        for (var i = 0; i < target.Count; i++)
        {
            var desired = target[i];
            if (i < Messages.Count && Messages[i].Value.TimelineKey.Equals(desired.TimelineKey,StringComparison.OrdinalIgnoreCase))
            {
                desired = PreserveStructurallyEqualCollections(Messages[i].Value, desired);
                if (Messages[i].Update(desired)) updated++;
                continue;
            }

            if (existingByKey.TryGetValue(desired.TimelineKey,out var existing))
            {
                // Existing message rows never move during refresh. New rows and
                // separators are inserted at their target positions, which shifts
                // stable containers naturally; moving an existing row recycles its
                // WinUI container and produces the visible white flash.
                desired = PreserveStructurallyEqualCollections(existing.Value, desired);
                if (existing.Update(desired)) updated++;
            }
            else
            {
                var entrance=MessageEntranceKind.None;
                if(entrances is not null)
                {
                    entrances.TryGetValue(desired.TimelineKey,out entrance);
                    if(entrance==MessageEntranceKind.None)entrances.TryGetValue(desired.PresentationKey,out entrance);
                    if(entrance==MessageEntranceKind.None&&desired.IsSeparator&&desired.PresentationKey.StartsWith("separator-",StringComparison.Ordinal))
                        entrances.TryGetValue(string.Concat(desired.ChatId,"\u001f",desired.PresentationKey[10..]),out entrance);
                }
                var row=new MessageRow(desired,entrance);
                Messages.Insert(i, row);
                existingByKey[desired.TimelineKey]=row;
                inserted++;
            }
        }

        while (Messages.Count > target.Count) { Messages.RemoveAt(Messages.Count - 1); removed++; }
        System.Diagnostics.Debug.WriteLine($"[MessageTimeline] insert={inserted} update={updated} remove={removed} rows={Messages.Count}");
    }

    /// <summary>
    /// ThreadPresentation deliberately creates fresh immutable records. Record equality is
    /// reference-based for IReadOnlyList properties, however, so an otherwise identical
    /// presentation pass used to replace every visible row. Keep the already-bound list
    /// instances when their contents are equal; WinUI then receives changes only for rows
    /// whose visible state actually changed.
    /// </summary>
    private static Message PreserveStructurallyEqualCollections(Message current, Message desired)
    {
        var media = current.Media.SequenceEqual(desired.Media) ? current.Attachments : desired.Attachments;
        var reactions = (current.Reactions ?? []).SequenceEqual(desired.Reactions ?? []) ? current.Reactions : desired.Reactions;
        return desired with { Attachments = media, Reactions = reactions };
    }
    private static IOrderedEnumerable<Message> OrderTimeline(IEnumerable<Message> rows)=>rows
        .OrderBy(row=>row.DateCreated).ThenBy(row=>row.SourceRowId)
        .ThenBy(row=>row.ChatId,StringComparer.OrdinalIgnoreCase).ThenBy(row=>row.Id,StringComparer.OrdinalIgnoreCase);
    private async Task RestorePendingUploadsAsync(string chatId,CancellationToken token)
    {
        var raw=_rawMessages.ToList();var resumed=new List<PendingUpload>();var changed=false;
        foreach(var upload in await _services.Cache.GetPendingUploadsAsync(chatId,token))
        {
            if(!File.Exists(upload.FilePath)){await _services.Cache.DeletePendingUploadAsync(upload.TempId,token);continue;}
            if(raw.Any(row=>row.PresentationKey==upload.TempId))continue;_pendingAttachmentPaths[upload.TempId]=upload.FilePath;
            var attachment=new Attachment(upload.TempId,upload.FileName,upload.MimeType,upload.Size);var delivery=upload.State=="failed"?MessageDeliveryState.Failed:upload.State=="sent_unconfirmed"?MessageDeliveryState.Sent:MessageDeliveryState.Sending;raw.Add(new Message(upload.TempId,upload.ChatId,"",DateTimeOffset.FromUnixTimeMilliseconds(upload.DateCreated).LocalDateTime.ToString("HH:mm"),true,delivery,AttachmentLabel:upload.FileName,DateCreated:upload.DateCreated,Attachments:[attachment],IsPending:true,ErrorText:upload.Error,PresentationId:upload.TempId));changed=true;
            if(upload.State=="sending")resumed.Add(upload);
        }
        if(changed)ApplyMessages(raw);foreach(var upload in resumed)_=ResumePendingUploadAsync(upload);
    }
    private async Task ResumePendingUploadAsync(PendingUpload upload){var row=_rawMessages.FirstOrDefault(item=>item.PresentationKey==upload.TempId);if(row is null)return;try{await UploadAttachmentAsync(row,upload.FilePath,CancellationToken.None);var index=_rawMessages.FindIndex(item=>item.PresentationKey==upload.TempId);if(index>=0&&_rawMessages[index].IsPending){var raw=_rawMessages.ToList();raw[index]=raw[index] with{DeliveryState=MessageDeliveryState.Sent,UploadProgress=1};ApplyMessages(raw);}await _services.Cache.UpsertPendingUploadAsync(upload with{State="sent_unconfirmed",Error=null});}catch(Exception exception){var index=_rawMessages.FindIndex(item=>item.PresentationKey==upload.TempId);if(index>=0&&_rawMessages[index].IsPending){var raw=_rawMessages.ToList();raw[index]=raw[index] with{DeliveryState=MessageDeliveryState.Failed,ErrorText=exception.Message};ApplyMessages(raw);}await _services.Cache.UpsertPendingUploadAsync(upload with{State="failed",Error=exception.Message});}}
    private static string MimeFor(string path) => Path.GetExtension(path).ToLowerInvariant() switch { ".jpg" or ".jpeg" => "image/jpeg", ".png" => "image/png", ".gif" => "image/gif", ".webp" => "image/webp", ".heic" or ".heif" => "image/heic", ".mov" => "video/quicktime", ".mp4" or ".m4v" => "video/mp4", ".m4a" => "audio/mp4", ".caf" => "audio/x-caf", ".mp3" => "audio/mpeg", ".wav" => "audio/wav", _ => "application/octet-stream" };
    private void Dispatch(Action action) { if (_dispatcher.HasThreadAccess) action(); else _dispatcher.TryEnqueue(() => action()); }
    public async ValueTask DisposeAsync() { foreach(var cancellation in _uploadCancellations.Values)cancellation.Cancel();_selectionCts?.Cancel();_selectionCts?.Dispose();if (_realtime is not null) await _realtime.DisposeAsync(); }
}

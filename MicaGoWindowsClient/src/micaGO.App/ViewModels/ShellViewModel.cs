using System.Collections.ObjectModel;
using Microsoft.UI.Dispatching;
using MicaGo.App.Services;
using MicaGo.Core.Models;
using MicaGo.Infrastructure.Connection;
using MicaGo.Infrastructure.Contracts;

namespace MicaGo.App.ViewModels;

public sealed class ShellViewModel : IAsyncDisposable
{
    private readonly DispatcherQueue _dispatcher;
    private readonly IMicaGoApi _api;
    private readonly AppServices _services;
    private RealtimeSyncService? _realtime;
    private IReadOnlyList<ChatSummary> _allChats = [];
    private List<Message> _rawMessages = [];
    private readonly Dictionary<string, string> _pendingAttachmentPaths = [];
    private readonly Dictionary<string,CancellationTokenSource> _uploadCancellations=[];
    private CancellationTokenSource? _selectionCts;
    private int _loadedMessageCount;
    private string _activeFilter=string.Empty;
    private const int MessagePageSize = 50;

    public ShellViewModel(DispatcherQueue dispatcher, IMicaGoApi api, AppServices services)
    {
        _dispatcher = dispatcher; _api = api; _services = services;
    }

    public ObservableCollection<ChatSummary> Chats { get; } = [];
    public ObservableCollection<Message> Messages { get; } = [];
    public ChatSummary? SelectedChat { get; private set; }
    public string SyncStatus { get; private set; } = "Cached";
    public bool IsLoadingOlder { get; private set; }
    public bool HasMoreMessages { get; private set; }
    public MessageActionCapabilities ActionCapabilities { get; private set; }=new(false,false,false);

    public event EventHandler? StateChanged;

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        await _services.Cache.InitializeAsync(cancellationToken);
        var cached = await _services.Cache.GetChatsAsync(cancellationToken);
        ReplaceChats(await ApplyContactNamesAsync(cached, cancellationToken));
        try
        {
            var remote = await _api.GetChatsAsync(cancellationToken);
            await _services.Cache.UpsertChatsAsync(remote, cancellationToken);
            ReplaceChats(await ApplyContactNamesAsync(remote, cancellationToken));
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
        var rows = _allChats.Where(chat => string.IsNullOrWhiteSpace(query) || chat.Title.Contains(query, StringComparison.CurrentCultureIgnoreCase) || chat.Preview.Contains(query, StringComparison.CurrentCultureIgnoreCase)).ToArray();
        Chats.Clear(); foreach (var row in rows) Chats.Add(row);
    }

    public void RefreshChatTimestamps()
    {
        _allChats=_allChats.Select(chat=>chat with{Time=ChatTimestamp(chat.UpdatedAt)}).ToArray();ApplyFilter(_activeFilter);
    }

    public string FormatActivityTimestamp(long milliseconds) => ChatTimestamp(milliseconds);

    public async Task RefreshContactsAsync(CancellationToken cancellationToken=default)
    {
        ReplaceChats(await ApplyContactNamesAsync(await _services.Cache.GetChatsAsync(cancellationToken),cancellationToken));
        if(SelectedChat is not{} selected)return;
        var updated=_allChats.FirstOrDefault(chat=>chat.Id==selected.Id||chat.RouteIds?.Contains(selected.Id)==true);if(updated is not null)SelectedChat=updated;
        ReplaceMessages(await DecorateMessageSendersAsync(_rawMessages,SelectedChat?.IsGroup==true,cancellationToken));
    }

    public async Task SelectChatAsync(ChatSummary chat, CancellationToken cancellationToken = default)
    {
        _selectionCts?.Cancel(); _selectionCts?.Dispose(); _selectionCts=CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);var token=_selectionCts.Token;
        SelectedChat = chat;
        _loadedMessageCount=MessagePageSize;
        var routes=chat.RouteIds is{Count:>0}?chat.RouteIds:[chat.Id];var cached=(await Task.WhenAll(routes.Select(route=>_services.Cache.GetMessagesAsync(route,MessagePageSize,cancellationToken:token)))).SelectMany(row=>row).OrderBy(row=>row.DateCreated).TakeLast(MessagePageSize).ToArray();
        token.ThrowIfCancellationRequested(); if(SelectedChat?.Id!=chat.Id)return;
        ReplaceMessages(await DecorateMessageSendersAsync(cached,chat.IsGroup,token));
        await RestorePendingUploadsAsync(chat.Id,token);
        try
        {
            var remote=(await Task.WhenAll(routes.Select(route=>_api.GetMessagesAsync(route,MessagePageSize,cancellationToken:token)))).SelectMany(row=>row).OrderBy(row=>row.DateCreated).TakeLast(MessagePageSize).ToArray();
            await _services.Cache.UpsertMessagesAsync(remote, token);
            token.ThrowIfCancellationRequested(); if(SelectedChat?.Id!=chat.Id)return;
            var refreshed=(await Task.WhenAll(routes.Select(route=>_services.Cache.GetMessagesAsync(route,MessagePageSize,cancellationToken:token)))).SelectMany(row=>row).OrderBy(row=>row.DateCreated).TakeLast(MessagePageSize).ToArray();
            ReplaceMessages(await DecorateMessageSendersAsync(refreshed,chat.IsGroup,token));
            await RestorePendingUploadsAsync(chat.Id,token);
            HasMoreMessages=remote.Length==MessagePageSize;
        }
        catch (OperationCanceledException) when(token.IsCancellationRequested){return;}
        catch when (cached.Length > 0) { HasMoreMessages=cached.Length==MessagePageSize; }
        await MarkSelectedChatReadAsync(chat,token);
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    public async Task LoadOlderMessagesAsync(CancellationToken cancellationToken=default)
    {
        if(SelectedChat is not{} chat||IsLoadingOlder||!HasMoreMessages)return;IsLoadingOlder=true;StateChanged?.Invoke(this,EventArgs.Empty);
        using var linked=CancellationTokenSource.CreateLinkedTokenSource(cancellationToken,_selectionCts?.Token??CancellationToken.None);var token=linked.Token;
        try{var page=await _api.GetMessagesAsync(chat.Id,MessagePageSize,_loadedMessageCount,token);await _services.Cache.UpsertMessagesAsync(page,token);if(SelectedChat?.Id!=chat.Id)return;_loadedMessageCount+=page.Count;HasMoreMessages=page.Count==MessagePageSize;var rows=await _services.Cache.GetMessagesAsync(chat.Id,_loadedMessageCount,cancellationToken:token);ReplaceMessages(await DecorateMessageSendersAsync(rows,chat.IsGroup,token));}
        catch(OperationCanceledException)when(token.IsCancellationRequested){}
        finally{IsLoadingOlder=false;StateChanged?.Invoke(this,EventArgs.Empty);}
    }

    private async Task MarkSelectedChatReadAsync(ChatSummary chat,CancellationToken token)
    {
        var latest=Messages.Count==0?0:Messages.Max(message=>message.DateCreated);await _services.Cache.SetSettingAsync("read.watermark."+chat.Id,latest.ToString(),token);
        var index=_allChats.ToList().FindIndex(item=>item.Id==chat.Id);if(index<0)return;var updated=_allChats[index] with{UnreadCount=0};var rows=_allChats.ToArray();rows[index]=updated;ReplaceChats(rows);SelectedChat=updated;
    }

    public async Task SendTextAsync(string text, CancellationToken cancellationToken = default)
    {
        if (SelectedChat is null || string.IsNullOrWhiteSpace(text)) return;
        var tempId = "local-" + Guid.NewGuid().ToString("N");
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var pending = new Message(tempId, SelectedChat.Id, text.Trim(), DateTime.Now.ToString("HH:mm"), true, MessageDeliveryState.Sending, DateCreated: now, IsPending: true, PresentationId: tempId);
        ReplaceMessages(_rawMessages.Append(pending));
        try
        {
            var confirmed = await _api.SendTextAsync(SelectedChat.Id, text.Trim(), tempId, cancellationToken);
            var index = _rawMessages.FindIndex(item=>item.PresentationKey==pending.PresentationKey); if (index >= 0){var raw=_rawMessages.ToList();raw[index]=confirmed with { PresentationId = pending.PresentationKey };ReplaceMessages(raw);}
            await _services.Cache.UpsertMessagesAsync([confirmed], cancellationToken);
        }
        catch (Exception exception)
        {
            var index = _rawMessages.FindIndex(item=>item.PresentationKey==pending.PresentationKey); if (index >= 0){var raw=_rawMessages.ToList();raw[index]=raw[index] with { DeliveryState = MessageDeliveryState.Failed, ErrorText = exception.Message };ReplaceMessages(raw);}
        }
    }

    public async Task SendAttachmentsAsync(IEnumerable<string> filePaths, CancellationToken cancellationToken = default)
    {
        if (SelectedChat is null) return;
        var staged = filePaths.Select((filePath, index) =>
        {
            var tempId = "local-" + Guid.NewGuid().ToString("N");
            var fileName = Path.GetFileName(filePath); var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + index;
            var attachment = new Attachment(tempId, fileName, MimeFor(filePath), new FileInfo(filePath).Length);
            var pending = new Message(tempId, SelectedChat.Id, string.Empty, DateTime.Now.ToString("HH:mm"), true, MessageDeliveryState.Sending, AttachmentLabel: fileName, DateCreated: now, Attachments: [attachment], IsPending: true, PresentationId: tempId);
            _pendingAttachmentPaths[tempId] = filePath;
            _= _services.Cache.UpsertPendingUploadAsync(new PendingUpload(tempId,SelectedChat.Id,filePath,fileName,attachment.MimeType,attachment.Size,now),cancellationToken);
            return (filePath, tempId, pending);
        }).ToArray();
        ReplaceMessages(_rawMessages.Concat(staged.Select(item=>item.pending)));
        foreach (var item in staged)
        {
            await _services.Media.SeedAsync(item.tempId, item.filePath, cancellationToken);
            try { await UploadAttachmentAsync(item.pending, item.filePath, cancellationToken); }
            catch (Exception exception) { var index = _rawMessages.FindIndex(row=>row.PresentationKey==item.pending.PresentationKey); if (index >= 0){var raw=_rawMessages.ToList();raw[index]=raw[index] with { DeliveryState = MessageDeliveryState.Failed, ErrorText = exception.Message };ReplaceMessages(raw);}await _services.Cache.UpsertPendingUploadAsync(new PendingUpload(item.tempId,item.pending.ChatId,item.filePath,item.pending.AttachmentLabel??Path.GetFileName(item.filePath),item.pending.Media[0].MimeType,item.pending.Media[0].Size,item.pending.DateCreated,"failed",exception.Message),cancellationToken); }
        }
    }

    public async Task EditAsync(Message message, string text, CancellationToken cancellationToken = default) { await _api.EditMessageAsync(message.ChatId, message.Id, text, cancellationToken: cancellationToken); if (_realtime is not null) await _realtime.CatchUpAsync(cancellationToken); }
    public async Task RetractAsync(Message message, CancellationToken cancellationToken = default) { await _api.RetractMessageAsync(message.ChatId, message.Id, cancellationToken: cancellationToken); if (_realtime is not null) await _realtime.CatchUpAsync(cancellationToken); }
    public async Task DeleteAsync(Message message, CancellationToken cancellationToken = default) { if(!message.IsPending)await _api.DeleteMessageAsync(message.ChatId, message.Id, cancellationToken);ReplaceMessages(_rawMessages.Where(item=>item.PresentationKey!=message.PresentationKey));_pendingAttachmentPaths.Remove(message.PresentationKey);await _services.Cache.DeletePendingUploadAsync(message.PresentationKey,cancellationToken);if(!message.IsPending)await _services.Cache.DeleteMessageAsync(message.Id, cancellationToken); }
    public async Task RetryAttachmentAsync(Message message, CancellationToken cancellationToken = default)
    {
        if (!_pendingAttachmentPaths.TryGetValue(message.PresentationKey, out var path) || !File.Exists(path)) return;
        var index=_rawMessages.FindIndex(item=>item.PresentationKey==message.PresentationKey); if(index<0)return; var sending=message with { DeliveryState=MessageDeliveryState.Sending, ErrorText=null, UploadProgress=0 };var raw=_rawMessages.ToList();raw[index]=sending;ReplaceMessages(raw);
        await _services.Cache.UpsertPendingUploadAsync(new PendingUpload(sending.Id,sending.ChatId,path,sending.AttachmentLabel??Path.GetFileName(path),sending.Media[0].MimeType,sending.Media[0].Size,sending.DateCreated),cancellationToken);
        try { await UploadAttachmentAsync(sending,path,cancellationToken); }
        catch(Exception exception){index=FindPresentationIndex(sending.PresentationKey);if(index>=0)Messages[index]=Messages[index] with{DeliveryState=MessageDeliveryState.Failed,ErrorText=exception.Message};}
    }
    public void CancelAttachmentUpload(Message message){if(_uploadCancellations.TryGetValue(message.PresentationKey,out var cancellation))cancellation.Cancel();}

    private async Task UploadAttachmentAsync(Message pending,string path,CancellationToken cancellationToken)
    {
        var uploadCancellation=CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);_uploadCancellations[pending.PresentationKey]=uploadCancellation;
        var progress=new Progress<double>(value=>
        {
            var row=Messages.FirstOrDefault(item=>item.PresentationKey==pending.PresentationKey);if(row is null)return;var index=Messages.IndexOf(row);if(index>=0)Messages[index]=row with{UploadProgress=value};
        });
        try{await _api.SendAttachmentAsync(pending.ChatId,pending.Id,path,progress:progress,cancellationToken:uploadCancellation.Token);}
        finally{_uploadCancellations.Remove(pending.PresentationKey);uploadCancellation.Dispose();}
    }

    private async void OnRealtimeMessagesChanged(object? sender, IReadOnlyList<Message> changed)
    {
        var selected=SelectedChat;var decorated=selected is null?changed:await DecorateMessageSendersAsync(changed,selected.IsGroup,CancellationToken.None);
        Dispatch(() =>
        {
            var raw = _rawMessages.ToList();
            foreach (var message in decorated)
            {
                var isSelected=SelectedChat is{} selected&&(selected.Id==message.ChatId||(selected.RouteIds?.Contains(message.ChatId)??false));
                if(isSelected)
                {
                    var existing = raw.FirstOrDefault(item => item.Id == message.Id);
                    if (existing is not null) raw[raw.IndexOf(existing)] = message with { PresentationId = existing.PresentationId };
                    else
                    {
                        var pending = MessageSemantics.MatchingPending(raw, message);
                        if (pending is not null){var index=raw.IndexOf(pending);raw[index]=message with{PresentationId=pending.PresentationKey};_pendingAttachmentPaths.Remove(pending.PresentationKey);_=_services.Cache.DeletePendingUploadAsync(pending.PresentationKey);}
                        else raw.Add(message);
                    }
                }
                UpdateChatForMessage(message,isSelected);
            }
            ReplaceMessages(raw);
            StateChanged?.Invoke(this, EventArgs.Empty);
        });
    }

    private void UpdateChatForMessage(Message message,bool isSelected)
    {
        var rows=_allChats.ToArray();var index=Array.FindIndex(rows,chat=>chat.Id==message.ChatId);if(index<0)return;var chat=rows[index];
        var preview=MessageSemantics.VisibleText(message.Text);if(string.IsNullOrEmpty(preview))preview=message.AttachmentLabel??"Attachment";
        rows[index]=chat with{Preview=preview,Time=message.SentAt,UpdatedAt=message.DateCreated,UnreadCount=!message.IsOutgoing&&!isSelected?chat.UnreadCount+1:chat.UnreadCount};
        ReplaceChats(rows.OrderByDescending(item=>item.IsPinned).ThenByDescending(item=>item.UpdatedAt));
        if(!message.IsOutgoing&&!isSelected&&!chat.IsMuted)_services.Notifications.Show(chat.Title,preview,message.ChatId);
    }

    private void ReplaceChats(IEnumerable<ChatSummary> rows) { _allChats = rows.ToArray(); ApplyFilter(string.Empty); }
    private async Task<IReadOnlyList<ChatSummary>> ApplyContactNamesAsync(IReadOnlyList<ChatSummary> rows, CancellationToken cancellationToken)
    {
        var result = new List<ChatSummary>(rows.Count);
        foreach (var chat in rows)
        {
            var locallyMuted=await _services.Cache.GetSettingAsync("chat.muted."+chat.Id,cancellationToken)=="1";var locallyPinned=await _services.Cache.GetSettingAsync("chat.pinned."+chat.Id,cancellationToken)=="1";var decorated=chat with{IsMuted=chat.IsMuted||locallyMuted,IsPinned=chat.IsPinned||locallyPinned};
            if (chat.IsGroup || chat.Participants is not { Count: > 0 }) { result.Add(decorated); continue; }
            var contact = await _services.Cache.ResolveContactAsync(chat.Participants[0], cancellationToken);
            if (contact is null) { result.Add(decorated); continue; }
            var initials = string.Concat(contact.DisplayName.Split(' ', StringSplitOptions.RemoveEmptyEntries).Take(2).Select(part => char.ToUpperInvariant(part[0])));
            result.Add(decorated with { Title = contact.DisplayName, Initials = string.IsNullOrWhiteSpace(initials) ? chat.Initials : initials, AvatarPath=contact.AvatarPath,RouteIds=[chat.Id] });
        }
        var merged=new List<ChatSummary>();foreach(var group in result.GroupBy(chat=>!chat.IsGroup&&chat.RouteIds is not null?"contact:"+chat.Title:"route:"+chat.Id,StringComparer.CurrentCultureIgnoreCase)){var routes=group.OrderByDescending(chat=>chat.UpdatedAt).ToArray();var primary=routes[0];merged.Add(routes.Length>1?primary with{RouteIds=routes.Select(route=>route.Id).ToArray(),Preview=primary.Preview}:primary);}return merged.OrderByDescending(chat=>chat.IsPinned).ThenByDescending(chat=>chat.UpdatedAt).Select(chat=>chat with{Time=ChatTimestamp(chat.UpdatedAt)}).ToArray();
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
    private void ReplaceMessages(IEnumerable<Message> rows)
    {
        _rawMessages=rows.Where(row=>!row.IsSeparator).OrderBy(row=>row.DateCreated).ToList();
        SyncMessages(ThreadPresentation.Build(_rawMessages,SelectedChat?.IsGroup==true,_services.Localization.Language));
    }

    /// <summary>
    /// Applies the freshly built presentation list to the bound collection as a
    /// keyed diff (update in place / insert / move / trim) instead of
    /// Clear()+Add(): a full reset makes the ListView drop its scroll position,
    /// which is why sending a message used to jump the thread to the top.
    /// </summary>
    private void SyncMessages(IReadOnlyList<Message> target)
    {
        var targetKeys = new HashSet<string>(target.Select(row => row.PresentationKey));
        for (var i = Messages.Count - 1; i >= 0; i--)
        {
            if (!targetKeys.Contains(Messages[i].PresentationKey)) Messages.RemoveAt(i);
        }

        for (var i = 0; i < target.Count; i++)
        {
            var desired = target[i];
            if (i < Messages.Count && Messages[i].PresentationKey == desired.PresentationKey)
            {
                if (!Messages[i].Equals(desired)) Messages[i] = desired;
                continue;
            }

            var existing = -1;
            for (var j = i + 1; j < Messages.Count; j++)
            {
                if (Messages[j].PresentationKey == desired.PresentationKey) { existing = j; break; }
            }

            if (existing >= 0)
            {
                Messages.Move(existing, i);
                if (!Messages[i].Equals(desired)) Messages[i] = desired;
            }
            else
            {
                Messages.Insert(i, desired);
            }
        }

        while (Messages.Count > target.Count) Messages.RemoveAt(Messages.Count - 1);
    }
    private async Task RestorePendingUploadsAsync(string chatId,CancellationToken token)
    {
        var raw=_rawMessages.ToList();var resumed=new List<PendingUpload>();var changed=false;
        foreach(var upload in await _services.Cache.GetPendingUploadsAsync(chatId,token))
        {
            if(!File.Exists(upload.FilePath)){await _services.Cache.DeletePendingUploadAsync(upload.TempId,token);continue;}
            if(raw.Any(row=>row.PresentationKey==upload.TempId))continue;_pendingAttachmentPaths[upload.TempId]=upload.FilePath;
            var attachment=new Attachment(upload.TempId,upload.FileName,upload.MimeType,upload.Size);raw.Add(new Message(upload.TempId,upload.ChatId,"",DateTimeOffset.FromUnixTimeMilliseconds(upload.DateCreated).LocalDateTime.ToString("HH:mm"),true,upload.State=="failed"?MessageDeliveryState.Failed:MessageDeliveryState.Sending,AttachmentLabel:upload.FileName,DateCreated:upload.DateCreated,Attachments:[attachment],IsPending:true,ErrorText:upload.Error,PresentationId:upload.TempId));changed=true;
            if(upload.State=="sending")resumed.Add(upload);
        }
        if(changed)ReplaceMessages(raw);foreach(var upload in resumed)_=ResumePendingUploadAsync(upload);
    }
    private async Task ResumePendingUploadAsync(PendingUpload upload){var row=Messages.FirstOrDefault(item=>item.PresentationKey==upload.TempId);if(row is null)return;try{await UploadAttachmentAsync(row,upload.FilePath,CancellationToken.None);}catch(Exception exception){var index=FindPresentationIndex(upload.TempId);if(index>=0)Messages[index]=Messages[index] with{DeliveryState=MessageDeliveryState.Failed,ErrorText=exception.Message};await _services.Cache.UpsertPendingUploadAsync(upload with{State="failed",Error=exception.Message});}}
    private int FindPresentationIndex(string key){for(var i=0;i<Messages.Count;i++)if(Messages[i].PresentationKey==key)return i;return -1;}
    private static string MimeFor(string path) => Path.GetExtension(path).ToLowerInvariant() switch { ".jpg" or ".jpeg" => "image/jpeg", ".png" => "image/png", ".gif" => "image/gif", ".webp" => "image/webp", ".heic" or ".heif" => "image/heic", ".mov" => "video/quicktime", ".mp4" or ".m4v" => "video/mp4", ".m4a" => "audio/mp4", ".caf" => "audio/x-caf", ".mp3" => "audio/mpeg", ".wav" => "audio/wav", _ => "application/octet-stream" };
    private void Dispatch(Action action) { if (_dispatcher.HasThreadAccess) action(); else _dispatcher.TryEnqueue(() => action()); }
    public async ValueTask DisposeAsync() { foreach(var cancellation in _uploadCancellations.Values)cancellation.Cancel();_selectionCts?.Cancel();_selectionCts?.Dispose();if (_realtime is not null) await _realtime.DisposeAsync(); }
}

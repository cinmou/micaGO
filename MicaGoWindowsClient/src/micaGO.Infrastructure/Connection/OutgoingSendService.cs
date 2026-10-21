using System.Collections.Concurrent;
using MicaGo.Core.Models;
using MicaGo.Infrastructure.Api;
using MicaGo.Infrastructure.Contracts;
using MicaGo.Infrastructure.Storage;

namespace MicaGo.Infrastructure.Connection;

public sealed record OutgoingSendUpdate(Message Message, bool IsNew=false);

/// <summary>One explicit-send pipeline for text, files, retries and forwarding. Never auto-replays.</summary>
public sealed class OutgoingSendService(IMicaGoApi api, LocalCacheStore cache, MediaCache media, string? fileRoot=null) : IDisposable
{
    private static string DefaultFileRoot=>Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"micaGO","pending_files");
    private readonly string _fileRoot=Path.GetFullPath(fileRoot??DefaultFileRoot);
    private readonly ConcurrentDictionary<string,CancellationTokenSource> _active=new();
    private readonly ConcurrentDictionary<string,byte> _removed=new();
    private readonly ConcurrentDictionary<string,string> _tracked=new();
    private readonly ConcurrentDictionary<string,string> _owned=new();
    private readonly SemaphoreSlim _attachments=new(1,1);
    private readonly CancellationTokenSource _lifetime=new();
    public event EventHandler<OutgoingSendUpdate>? Changed;
    public event EventHandler<string>? Removed;

    public async Task<MessageDeliveryState> SendTextAsync(string route,string text,CancellationToken ct=default)
    {
        var send=new PendingSend(NewId(),route,"","","text/plain",0,Now(),Text:text.Trim());
        await cache.UpsertPendingSendAsync(send,ct);
        Publish(send,true);
        return await TransmitAsync(send,ct);
    }

    public async Task<IReadOnlyList<MessageDeliveryState>> SendFilesAsync(string route,IEnumerable<string> paths,bool voice=false,CancellationToken ct=default)
    {
        var queue=paths.Select((path,index)=>new PendingSend(NewId(),route,path,Path.GetFileName(path),MimeFor(path),0,Now()+index,IsAudioMessage:voice)).ToArray();
        // Every accepted item gets a durable row before the first upload starts.
        var accepted=new List<PendingSend>();
        try {foreach(var send in queue){await cache.UpsertPendingSendAsync(send,ct);accepted.Add(send);Publish(send,true);}}
        catch(Exception error){foreach(var send in accepted)await FailBeforeDispatchAsync(send,error);throw;}
        var results=new List<MessageDeliveryState>();
        foreach(var initial in queue)
        {
            if(_removed.ContainsKey(initial.TempId))continue;
            var send=initial;
            try { send=await SnapshotAsync(send,ct); await cache.UpdatePendingSendAsync(send,ct); }
            catch(Exception error) { await FailBeforeDispatchAsync(send,error);results.Add(MessageDeliveryState.Failed);continue; }
            results.Add(await TransmitAsync(send,ct));
        }
        return results;
    }

    public async Task<MessageDeliveryState> SendForwardFileAsync(string route,string source,string? name,bool voice,CancellationToken ct=default)
    {
        var send=new PendingSend(NewId(),route,source,SafeFileName(name??Path.GetFileName(source)),MimeFor(name??source),0,Now(),IsAudioMessage:voice);
        await cache.UpsertPendingSendAsync(send,ct);Publish(send,true);
        try {send=await SnapshotAsync(send,ct);await cache.UpdatePendingSendAsync(send,ct);}
        catch(Exception error){await FailBeforeDispatchAsync(send,error);return MessageDeliveryState.Failed;}
        return await TransmitAsync(send,ct);
    }
    public void Acknowledge(string id)
    {
        _removed.TryAdd(id,0);_tracked.TryRemove(id,out _);
        if(_owned.TryRemove(id,out var path))CleanupOwned(path);
    }

    public async Task ReconcileAsync(CancellationToken ct=default)
    {
        var pending=(await cache.GetPendingSendsAsync(cancellationToken:ct)).Select(row=>row.TempId).ToHashSet(StringComparer.Ordinal);
        foreach(var id in _tracked.Keys)if(!pending.Contains(id))Acknowledge(id);
    }
    public async Task PruneFilesAsync(CancellationToken ct=default)
    {
        var retained=(await cache.GetPendingSendsAsync(cancellationToken:ct)).Where(row=>!row.IsText).Select(row=>Path.GetFullPath(row.FilePath)).ToHashSet(StringComparer.OrdinalIgnoreCase);
        if(!Directory.Exists(_fileRoot))return;
        foreach(var directory in Directory.EnumerateDirectories(_fileRoot).Where(path=>(File.GetAttributes(path)&FileAttributes.ReparsePoint)==0))
            foreach(var file in Directory.EnumerateFiles(directory))if(!retained.Contains(Path.GetFullPath(file)))CleanupOwned(file);
    }

    public static void ClearOwnedFiles()
    {
        if(!Directory.Exists(DefaultFileRoot))return;
        foreach(var directory in Directory.EnumerateDirectories(DefaultFileRoot).Where(path=>(File.GetAttributes(path)&FileAttributes.ReparsePoint)==0)) {
            try{foreach(var file in Directory.EnumerateFiles(directory))File.Delete(file);if(!Directory.EnumerateFileSystemEntries(directory).Any())Directory.Delete(directory);}
            catch(IOException){}catch(UnauthorizedAccessException){}
        }
    }

    public async Task<bool> RetryAsync(Message message,CancellationToken ct=default)
    {
        var previous=(await cache.GetPendingSendsAsync(message.ChatId,ct)).FirstOrDefault(row=>row.TempId==message.PresentationKey);
        if(previous is null||previous.State!="failed")return false;
        var next=previous with{TempId=NewId(),DateCreated=Now(),State="queued",Error=null};
        if(!await cache.ReplaceFailedPendingSendAsync(previous,next,ct))return false;
        _removed.TryAdd(previous.TempId,0);Removed?.Invoke(this,previous.TempId);
        Publish(next,true);
        if(!next.IsText)
        {
            try { next=await SnapshotAsync(next,ct);await cache.UpdatePendingSendAsync(next,ct); }
            catch(Exception error){await FailBeforeDispatchAsync(next,error);return true;}
        }
        CleanupOwned(previous.FilePath,except:next.FilePath);
        await TransmitAsync(next,ct);
        return true;
    }

    public void Cancel(Message message)
    {
        if(_active.TryGetValue(message.PresentationKey,out var transfer))transfer.Cancel();
    }

    public async Task DeleteAsync(Message message,CancellationToken ct=default)
    {
        var send=(await cache.GetPendingSendsAsync(message.ChatId,ct)).FirstOrDefault(row=>row.TempId==message.PresentationKey);
        _removed.TryAdd(message.PresentationKey,0);Cancel(message);
        await cache.DeletePendingSendAsync(message.PresentationKey,ct);
        Removed?.Invoke(this,message.PresentationKey);
        if(send is not null)CleanupOwned(send.FilePath);
    }

    private async Task<PendingSend> SnapshotAsync(PendingSend send,CancellationToken ct)
    {
        if(!File.Exists(send.FilePath))throw new FileNotFoundException("The attachment file is no longer available.");
        var directory=Path.Combine(_fileRoot,send.TempId);
        Directory.CreateDirectory(directory);
        var destination=Path.Combine(directory,SafeFileName(send.FileName));
        if(!string.Equals(Path.GetFullPath(send.FilePath),destination,StringComparison.OrdinalIgnoreCase))
        {
            await using var source=File.OpenRead(send.FilePath);
            await using var output=File.Create(destination);
            await source.CopyToAsync(output,ct);
        }
        if(_removed.ContainsKey(send.TempId)){CleanupOwned(destination);throw new OperationCanceledException();}
        await media.SeedAsync(send.TempId,destination,ct);
        var staged=send with{FilePath=destination,FileName=Path.GetFileName(destination),Size=new FileInfo(destination).Length};
        _owned[send.TempId]=destination;
        Publish(staged);
        return staged;
    }

    private async Task<MessageDeliveryState> TransmitAsync(PendingSend send,CancellationToken ct)
    {
        using var transfer=CancellationTokenSource.CreateLinkedTokenSource(ct,_lifetime.Token);
        if(!_active.TryAdd(send.TempId,transfer))return MessageDeliveryState.Sending;
        var entered=false;var dispatched=false;Message? confirmed=null;
        var delivery=MessageDeliveryState.Sent;string? error=null;
        try
        {
            if(!send.IsText){await _attachments.WaitAsync(transfer.Token);entered=true;}
            if(_removed.ContainsKey(send.TempId)||(await cache.GetPendingSendsAsync(send.ChatId,transfer.Token)).All(row=>row.TempId!=send.TempId))return MessageDeliveryState.Sent;
            transfer.Token.ThrowIfCancellationRequested();
            await cache.UpdatePendingSendAsync(send with{State="sending"},transfer.Token);
            dispatched=true;
            if(send.IsText)confirmed=await api.SendTextAsync(send.ChatId,send.Text!,send.TempId,transfer.Token);
            else await api.SendAttachmentAsync(send.ChatId,send.TempId,send.FilePath,isAudioMessage:send.IsAudioMessage,
                progress:new InlineProgress(value=>{if(!_removed.ContainsKey(send.TempId))Changed?.Invoke(this,new(send.ToMessage(true) with{UploadProgress=value}));}),cancellationToken:transfer.Token);
        }
        catch(Exception failure)
        {
            delivery=dispatched?SendOutcome.FromException(failure,transfer.Token):MessageDeliveryState.Failed;
            if(delivery==MessageDeliveryState.Failed)error=failure.Message;
        }
        finally {if(entered)_attachments.Release();_active.TryRemove(send.TempId,out _);}
        if(_removed.ContainsKey(send.TempId))return delivery;
        if(confirmed is not null)
        {
            confirmed=confirmed with{PresentationId=send.TempId};
            // A disk error after acceptance must never turn a successful send into a retryable rejection.
            try {await cache.UpsertMessagesAsync([confirmed],CancellationToken.None);}
            catch {await SetStateAsync(send,"sent_unconfirmed",null);}
            Changed?.Invoke(this,new(confirmed));CleanupOwned(send.FilePath);
            return MessageDeliveryState.Sent;
        }
        var state=delivery==MessageDeliveryState.Failed?"failed":delivery==MessageDeliveryState.Sent?"sent_unconfirmed":"awaiting_confirmation";
        await SetStateAsync(send,state,error);
        return delivery;
    }

    private async Task FailBeforeDispatchAsync(PendingSend send,Exception error)
    {
        await SetStateAsync(send,"failed",error.Message);
        var staged=Path.Combine(_fileRoot,send.TempId,SafeFileName(send.FileName));
        CleanupOwned(staged,except:send.FilePath);
    }

    private async Task SetStateAsync(PendingSend send,string state,string? error)
    {
        var updated=send with{State=state,Error=error};
        try{await cache.UpdatePendingSendAsync(updated,CancellationToken.None);}
        catch(Exception failure) when(failure is IOException or UnauthorizedAccessException or Microsoft.Data.Sqlite.SqliteException) { /* Retain the durable pre-dispatch state for conservative recovery. */ }
        if(!_removed.ContainsKey(send.TempId))Publish(updated);
    }
    private void Publish(PendingSend send,bool fresh=false){if(fresh)_tracked[send.TempId]=send.ChatId;if(!_removed.ContainsKey(send.TempId))Changed?.Invoke(this,new(send.ToMessage(true),fresh));}
    private void CleanupOwned(string path,string? except=null)
    {
        if(string.IsNullOrWhiteSpace(path)||path==except)return;
        var full=Path.GetFullPath(path);
        if(!full.StartsWith(_fileRoot+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase))return;
        try {File.Delete(full);var directory=Path.GetDirectoryName(full)!;if(Directory.Exists(directory)&&!Directory.EnumerateFileSystemEntries(directory).Any())Directory.Delete(directory);}
        catch(IOException){}catch(UnauthorizedAccessException){}
    }
    public static string SafeFileName(string name)
    {
        var safe=Path.GetFileName(name.Replace('\\','/'));
        return string.IsNullOrWhiteSpace(safe)||safe is "." or ".."?"attachment":string.Concat(safe.Select(c=>Path.GetInvalidFileNameChars().Contains(c)?'_':c));
    }
    public static string MimeFor(string path)=>Path.GetExtension(path).ToLowerInvariant() switch {
        ".jpg" or ".jpeg"=>"image/jpeg",".png"=>"image/png",".gif"=>"image/gif",".webp"=>"image/webp",".heic" or ".heif"=>"image/heic",".mov"=>"video/quicktime",".mp4" or ".m4v"=>"video/mp4",".m4a"=>"audio/mp4",".caf"=>"audio/x-caf",".mp3"=>"audio/mpeg",".wav"=>"audio/wav",_=>"application/octet-stream"};
    private static string NewId()=>"local-"+Guid.NewGuid().ToString("N");
    private static long Now()=>DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    private sealed class InlineProgress(Action<double> report):IProgress<double>{public void Report(double value)=>report(value);}
    public void Dispose(){_lifetime.Cancel();foreach(var transfer in _active.Values)transfer.Cancel();}
}

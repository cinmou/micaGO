using System.Runtime.CompilerServices;
using Microsoft.Data.Sqlite;
using MicaGo.Core.Models;
using MicaGo.Infrastructure.Connection;
using MicaGo.Infrastructure.Contracts;
using MicaGo.Infrastructure.Storage;

internal static class RealtimeSyncTests
{
    public static async Task RunAsync()
    {
        var path=Path.Combine(Path.GetTempPath(),"micago-sync-"+Guid.NewGuid().ToString("N")+".db");
        LocalCacheStore? cache=null;
        try
        {
            cache=new LocalCacheStore(path);var api=new FakeApi();
            api.Deltas.Enqueue(new MessageDelta([Message("m2",200),Message("m1",100)],[],2,true));
            api.Deltas.Enqueue(new MessageDelta([Message("m2",200),Message("m3",300)],[],3,false));
            await using var sync=new RealtimeSyncService(api,cache);await sync.CatchUpAsync();
            var rows=await cache.GetMessagesAsync("chat",20);Equal("m1,m2,m3",string.Join(',',rows.Select(row=>row.Id)));Equal("3",await cache.GetSettingAsync("sync.cursor"));

            var live=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);sync.StatusChanged+=(_,status)=>{if(status=="Live")live.TrySetResult();};sync.Start();await live.Task.WaitAsync(TimeSpan.FromSeconds(2));
            api.Deltas.Enqueue(new MessageDelta([Message("m4",400)],[],4,false));api.EmitRealtime();
            using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(3));while((await cache.GetMessagesAsync("chat",20,0,timeout.Token)).All(row=>row.Id!="m4"))await Task.Delay(20,timeout.Token);
        }
        finally{cache?.Dispose();SqliteConnection.ClearAllPools();foreach(var suffix in new[]{"","-wal","-shm"})if(File.Exists(path+suffix))File.Delete(path+suffix);}
    }

    private static Message Message(string id,long at)=>new(id,"chat",id,"",false,MessageDeliveryState.Delivered,DateCreated:at);
    private static void Equal(string? expected,string? actual){if(expected!=actual)throw new InvalidOperationException($"Expected {expected}, got {actual}");}

    private sealed class FakeApi : IMicaGoApi
    {
        private readonly System.Threading.Channels.Channel<RealtimeEvent> _events=System.Threading.Channels.Channel.CreateUnbounded<RealtimeEvent>();
        public Queue<MessageDelta> Deltas{get;}=[];public string BaseUrl=>"http://fake";public void EmitRealtime()=>_events.Writer.TryWrite(new("message:new","chat",null));
        public Task<MessageDelta> GetMessagesDeltaAsync(long? since,int limit=200,CancellationToken cancellationToken=default)=>Task.FromResult(Deltas.Count>0?Deltas.Dequeue():new MessageDelta([],[],since??0,false));
        public async IAsyncEnumerable<RealtimeEvent> ListenRealtimeAsync([EnumeratorCancellation] CancellationToken cancellationToken=default){await foreach(var item in _events.Reader.ReadAllAsync(cancellationToken))yield return item;}
        public Task<IReadOnlyList<ChatSummary>> GetChatsAsync(CancellationToken cancellationToken=default)=>Task.FromResult<IReadOnlyList<ChatSummary>>([]);
        public Task<IReadOnlyList<Message>> GetMessagesAsync(string chatId,int limit=50,int offset=0,CancellationToken cancellationToken=default)=>Task.FromResult<IReadOnlyList<Message>>([]);
        public Task<Message> SendTextAsync(string chatId,string text,string? tempId=null,CancellationToken cancellationToken=default)=>throw new NotSupportedException();
        public Task<AttachmentUploadResult> SendAttachmentAsync(string chatId,string tempId,string filePath,bool isAudioMessage=false,IProgress<double>? progress=null,CancellationToken cancellationToken=default)=>throw new NotSupportedException();
        public Task<byte[]> GetAttachmentBytesAsync(string attachmentId,bool preview=false,bool playable=false,CancellationToken cancellationToken=default)=>throw new NotSupportedException();
        public Task<MessageActionCapabilities> GetMessageActionCapabilitiesAsync(CancellationToken cancellationToken=default)=>Task.FromResult(new MessageActionCapabilities(false,false,false));
        public Task EditMessageAsync(string chatId,string messageId,string text,int partIndex=0,CancellationToken cancellationToken=default)=>Task.CompletedTask;
        public Task RetractMessageAsync(string chatId,string messageId,int partIndex=0,CancellationToken cancellationToken=default)=>Task.CompletedTask;
        public Task DeleteMessageAsync(string chatId,string messageId,CancellationToken cancellationToken=default)=>Task.CompletedTask;
        public void Dispose()=>_events.Writer.TryComplete();
    }
}

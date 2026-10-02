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
            await using (var db = new SqliteConnection($"Data Source={path}")) {
                await db.OpenAsync();
                await using var command = db.CreateCommand();
                command.CommandText = "CREATE TRIGGER reject_delta BEFORE INSERT ON messages WHEN NEW.guid='failed-page' BEGIN SELECT RAISE(ABORT,'simulated write failure'); END";
                await command.ExecuteNonQueryAsync();
                api.Deltas.Enqueue(new MessageDelta([Message("failed-page",350)],[],4,false));
                try { await sync.CatchUpAsync(); throw new InvalidOperationException("Expected a failed cache write."); }
                catch (SqliteException) { }
                Equal("3",await cache.GetSettingAsync("sync.cursor"));
                command.CommandText = "DROP TRIGGER reject_delta";
                await command.ExecuteNonQueryAsync();
                api.Deltas.Enqueue(new MessageDelta([Message("failed-page",350)],[],4,false));
                await sync.CatchUpAsync();
                True((await cache.GetMessagesAsync("chat",20)).Any(row=>row.Id=="failed-page"),"failed page could not replay");
            }
            await cache.UpsertMessagesAsync([new Message("shared","route-a","A","",false,MessageDeliveryState.Read,DateCreated:10),new Message("shared","route-b","B","",false,MessageDeliveryState.Read,DateCreated:20)]);
            Equal("A",(await cache.GetMessagesAsync("route-a",20)).Single().Text);
            Equal("B",(await cache.GetMessagesAsync("route-b",20)).Single().Text);

            var live=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);var delivered=new TaskCompletionSource<RealtimeMessageBatch>(TaskCreationOptions.RunContinuationsAsynchronously);sync.MessagesChanged+=(_,batch)=>{if(batch.Messages.Any(message=>message.Id=="m4"))delivered.TrySetResult(batch);};sync.StatusChanged+=(_,status)=>{if(status=="Live")live.TrySetResult();};sync.Start();await live.Task.WaitAsync(TimeSpan.FromSeconds(2));
            var capabilities=new TaskCompletionSource<MessageActionCapabilities>(TaskCreationOptions.RunContinuationsAsynchronously);
            sync.CapabilitiesChanged+=(_,value)=>capabilities.TrySetResult(value);
            api.ActionCapabilities=new(true,false,true);api.EmitRealtime("capabilities:updated");
            var refreshed=await capabilities.Task.WaitAsync(TimeSpan.FromSeconds(3));
            True(refreshed.CanEdit&&refreshed.CanDelete&&!refreshed.CanRetract,"helper event did not refresh action capabilities");
            api.Deltas.Enqueue(new MessageDelta([Message("m4",400)],[],4,false));api.EmitRealtime();
            using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(3));while((await cache.GetMessagesAsync("chat",20,0,timeout.Token)).All(row=>row.Id!="m4"))await Task.Delay(20,timeout.Token);
            var deliveredBatch=await delivered.Task.WaitAsync(TimeSpan.FromSeconds(3));True(deliveredBatch.AllowNotifications,"live catch-up did not allow notifications");

            var freshPath=Path.Combine(Path.GetTempPath(),"micago-sync-fresh-"+Guid.NewGuid().ToString("N")+".db");
            try
            {
                using var freshCache=new LocalCacheStore(freshPath);var freshApi=new FakeApi();freshApi.Deltas.Enqueue(new MessageDelta([Message("history",50)],[],1,false));
                await using var freshSync=new RealtimeSyncService(freshApi,freshCache);var initial=new TaskCompletionSource<RealtimeMessageBatch>(TaskCreationOptions.RunContinuationsAsynchronously);freshSync.MessagesChanged+=(_,batch)=>initial.TrySetResult(batch);freshSync.Start();
                var first=await initial.Task.WaitAsync(TimeSpan.FromSeconds(2));True(!first.AllowNotifications,"initial history catch-up was notification eligible");
            }
            finally{SqliteConnection.ClearAllPools();foreach(var suffix in new[]{"","-wal","-shm"})if(File.Exists(freshPath+suffix))File.Delete(freshPath+suffix);}
        }
        finally{cache?.Dispose();SqliteConnection.ClearAllPools();foreach(var suffix in new[]{"","-wal","-shm"})if(File.Exists(path+suffix))File.Delete(path+suffix);}
    }

    private static Message Message(string id,long at)=>new(id,"chat",id,"",false,MessageDeliveryState.Delivered,DateCreated:at);
    private static void Equal(string? expected,string? actual){if(expected!=actual)throw new InvalidOperationException($"Expected {expected}, got {actual}");}
    private static void True(bool value,string message){if(!value)throw new InvalidOperationException(message);}

    internal class FakeApi : IMicaGoApi
    {
        public virtual Task<ReadState> GetReadStateAsync(CancellationToken ct=default)=>Task.FromResult(new ReadState(new string('a',32),0,[]));
        public virtual Task<ReadState> PatchReadStateAsync(ReadStateMutation mutation,CancellationToken ct=default)=>throw new NotSupportedException();
        public virtual Task<MessagePreferences> GetMessagePreferencesAsync(CancellationToken cancellationToken=default)=>Task.FromResult(new MessagePreferences(new string('a',32),0,[]));
        public virtual Task<MessagePreferences> PatchMessagePreferencesAsync(MessagePreferenceMutation mutation,CancellationToken cancellationToken=default)=>throw new NotSupportedException();
        public virtual Task<ChatPreferences> GetChatPreferencesAsync(CancellationToken cancellationToken=default)=>Task.FromResult(new ChatPreferences("test",0,[]));
        public virtual Task<ChatPreferences> PatchChatPreferencesAsync(ChatPreferenceMutation mutation,CancellationToken cancellationToken=default)=>throw new NotSupportedException();
        private readonly System.Threading.Channels.Channel<RealtimeEvent> _events=System.Threading.Channels.Channel.CreateUnbounded<RealtimeEvent>();
        public Queue<MessageDelta> Deltas{get;}=[];public string BaseUrl=>"http://fake";public void EmitRealtime(string type="message:new")=>_events.Writer.TryWrite(new(type,"chat",null));
        public Task<MessageDelta> GetMessagesDeltaAsync(long? since,int limit=200,CancellationToken cancellationToken=default)=>Task.FromResult(Deltas.Count>0?Deltas.Dequeue():new MessageDelta([],[],since??0,false));
        public async IAsyncEnumerable<RealtimeEvent> ListenRealtimeAsync([EnumeratorCancellation] CancellationToken cancellationToken=default){await foreach(var item in _events.Reader.ReadAllAsync(cancellationToken))yield return item;}
        public Task<IReadOnlyList<ChatSummary>> GetChatsAsync(CancellationToken cancellationToken=default)=>Task.FromResult<IReadOnlyList<ChatSummary>>([]);
        public Task<MessageHistoryPage> GetMessageHistoryAsync(IReadOnlyList<string> chatIds,int limit=50,string? before=null,CancellationToken cancellationToken=default)=>Task.FromResult(new MessageHistoryPage([],null,false));
        public virtual Task<Message> SendTextAsync(string chatId,string text,string? tempId=null,CancellationToken cancellationToken=default)=>throw new NotSupportedException();
        public Task<AttachmentUploadResult> SendAttachmentAsync(string chatId,string tempId,string filePath,bool isAudioMessage=false,IProgress<double>? progress=null,CancellationToken cancellationToken=default)=>throw new NotSupportedException();
        public Task<byte[]> GetAttachmentBytesAsync(string attachmentId,bool preview=false,bool playable=false,CancellationToken cancellationToken=default)=>throw new NotSupportedException();
        public Task<bool> GetTestContactEnabledAsync(CancellationToken cancellationToken=default)=>Task.FromResult(false);
        public Task SetTestContactEnabledAsync(bool enabled,CancellationToken cancellationToken=default)=>Task.CompletedTask;
        public Task<ServerSyncSettings> GetSyncSettingsAsync(CancellationToken cancellationToken=default)=>Task.FromResult(new ServerSyncSettings("hybrid",100,true,true,true,false,false,false));
        public Task<ServerSyncSettings> SetSyncSettingsAsync(ServerSyncSettings settings,CancellationToken cancellationToken=default)=>Task.FromResult(settings);
        public Task<string> RegisterDeviceAsync(DeviceRegistration registration,CancellationToken cancellationToken=default)=>Task.FromResult(registration.Id);
        public Task HeartbeatDeviceAsync(string deviceId,CancellationToken cancellationToken=default)=>Task.CompletedTask;
        public MessageActionCapabilities ActionCapabilities {get;set;}=new(false,false,false);
        public Task<MessageActionCapabilities> GetMessageActionCapabilitiesAsync(CancellationToken cancellationToken=default)=>Task.FromResult(ActionCapabilities);
        public Task EditMessageAsync(string chatId,string messageId,string text,int partIndex=0,CancellationToken cancellationToken=default)=>Task.CompletedTask;
        public Task RetractMessageAsync(string chatId,string messageId,int partIndex=0,CancellationToken cancellationToken=default)=>Task.CompletedTask;
        public Task DeleteMessageAsync(string chatId,string messageId,CancellationToken cancellationToken=default)=>Task.CompletedTask;
        public void Dispose()=>_events.Writer.TryComplete();
    }
}

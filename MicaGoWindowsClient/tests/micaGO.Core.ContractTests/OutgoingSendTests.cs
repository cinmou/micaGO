using Microsoft.Data.Sqlite;
using MicaGo.Core.Models;
using MicaGo.Infrastructure.Api;
using MicaGo.Infrastructure.Connection;
using MicaGo.Infrastructure.Storage;
using System.Text.Json;

internal static class OutgoingSendTests
{
    public static async Task RunAsync()
    {
        using(var f=new Fixture()) {
            var updates=new List<OutgoingSendUpdate>();f.Sender.Changed+=(_,value)=>updates.Add(value);
            f.Api.Text=(_,_,_)=>throw new MicaGoApiException("rejected",400);
            Check(await f.Sender.SendTextAsync("phone","hello")==MessageDeliveryState.Failed,"explicit rejection");
            var failed=(await f.Cache.GetPendingSendsAsync("phone")).Single();
            Check(failed.Text=="hello"&&failed.State=="failed","text must survive restart");
            Check(updates[0].IsNew&&updates[0].Message.DeliveryState==MessageDeliveryState.Sending,"optimistic stage");
            var hold=new TaskCompletionSource<Message>(TaskCreationOptions.RunContinuationsAsynchronously);
            f.Api.Text=(_,_,_)=>hold.Task;
            var retry=f.Sender.RetryAsync(failed.ToMessage());
            while(f.Api.TextCalls<2)await Task.Yield();
            Check(!await f.Sender.RetryAsync(failed.ToMessage()),"concurrent retry must have one winner");
            var next=(await f.Cache.GetPendingSendsAsync("phone")).Single();
            Check(next.TempId!=failed.TempId&&next.DateCreated>=failed.DateCreated,"manual retry uses fresh identity");
            hold.SetResult(new("server","phone","hello","",true,MessageDeliveryState.Sent,DateCreated:next.DateCreated));
            await retry;
            Check((await f.Cache.GetPendingSendsAsync("phone")).Count==0,"accepted text removes pending record");
            Check(updates.Last().Message.PresentationKey==next.TempId&&!updates.Last().Message.IsPending,"stable accepted presentation");
        }
        using(var f=new Fixture()) {
            f.Api.Text=(_,_,_)=>throw new TimeoutException();
            await f.Sender.SendTextAsync("email","uncertain");
            var row=(await f.Cache.GetPendingSendsAsync("email")).Single();
            Check(row.State=="awaiting_confirmation"&&!await f.Sender.RetryAsync(row.ToMessage()),"uncertain text cannot replay");
            await f.Cache.ClearContentCacheAsync();
            Check((await f.Cache.GetPendingSendsAsync("email")).Count==1,"cache clear preserves outgoing queue");
            await f.Cache.ClearContentCacheAsync(discardPending:true);
            Check((await f.Cache.GetPendingSendsAsync()).Count==0,"unpair clears outgoing queue");
        }
        using(var f=new Fixture()) {
            var source=Path.Combine(f.Root,"voice.m4a");await File.WriteAllTextAsync(source,"voice bytes");
            f.Api.File=(_,_,_,voice,_)=>throw new MicaGoApiException("rejected",400);
            await f.Sender.SendFilesAsync("phone",[source],voice:true);
            var failed=(await f.Cache.GetPendingSendsAsync("phone")).Single();
            Check(failed.IsAudioMessage&&failed.FilePath!=source&&File.Exists(failed.FilePath),"owned voice copy");
            File.Delete(source);
            f.Api.File=async(route,id,path,voice,progress)=>{
                Check(route=="phone"&&voice&&await File.ReadAllTextAsync(path)=="voice bytes","retry retains route, voice and bytes");
                return new(Path.GetFileName(path));
            };
            await f.Sender.RetryAsync(failed.ToMessage());
            var next=(await f.Cache.GetPendingSendsAsync("phone")).Single();
            Check(next.State=="sent_unconfirmed"&&!File.Exists(failed.FilePath),"retry retains only current snapshot");
            var server=new Message("voice-server","phone","","",true,MessageDeliveryState.Sent,DateCreated:next.DateCreated,
                Attachments:[new("voice","voice.m4a","audio/mp4",next.Size,IsVoiceMessage:true)]);
            await f.Cache.UpsertMessagesAsync([server]);await f.Sender.ReconcileAsync();
            Check(!File.Exists(next.FilePath),"late attachment confirmation cleans owned copy");
        }
        using(var f=new Fixture()) {
            var valid=Path.Combine(f.Root,"valid.png");await File.WriteAllTextAsync(valid,"image bytes");
            var results=await f.Sender.SendFilesAsync("route",[Path.Combine(f.Root,"missing.png"),valid]);
            Check(results.SequenceEqual(new[]{MessageDeliveryState.Failed,MessageDeliveryState.Sent}),"missing file must not strand the batch");
            Check(f.Api.FileCalls==1,"missing source never dispatched");
            var missing=(await f.Cache.GetPendingSendsAsync("route")).Single(row=>row.State=="failed");
            Check(!string.IsNullOrWhiteSpace(missing.Error),"missing source shows recoverable error");
            await f.Sender.DeleteAsync(missing.ToMessage());
            Check((await f.Cache.GetPendingSendsAsync("route")).Count==1,"delete only requested pending row");
            await f.Sender.SendForwardFileAsync("preferred-route",valid,"../../original.png",true);
            Check(f.Api.LastRoute=="preferred-route"&&f.Api.LastName=="original.png"&&f.Api.LastVoice,"forward keeps safe original name and selected route");
        }
        using(var f=new Fixture()) {
            var source=Path.Combine(f.Root,"cancel.png");await File.WriteAllTextAsync(source,"bytes");
            var dispatched=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            f.Api.File=async(_,_,_,_,_)=>{dispatched.SetResult();await Task.Delay(Timeout.Infinite,f.Api.FileToken);return new(null);};
            var send=f.Sender.SendFilesAsync("route",[source]);await dispatched.Task;
            var row=(await f.Cache.GetPendingSendsAsync("route")).Single();f.Sender.Cancel(row.ToMessage());
            await send;
            Check((await f.Cache.GetPendingSendsAsync("route")).Single().State=="awaiting_confirmation","cancel after dispatch stays uncertain");
        }
        using(var f=new Fixture()) {
            // Upgrade the historical upload-only schema without losing retry state.
            var legacy=new PendingSend("legacy","route","missing","voice.m4a","audio/mp4",1,1,"failed");
            await using(var db=new SqliteConnection($"Data Source={f.Database}")) {
                await db.OpenAsync();await using var command=db.CreateCommand();
                command.CommandText="CREATE TABLE pending_uploads(temp_id TEXT PRIMARY KEY,chat_guid TEXT,date_created INTEGER,json TEXT);INSERT INTO pending_uploads VALUES('legacy','route',1,$json)";
                command.Parameters.AddWithValue("$json",JsonSerializer.Serialize(legacy));await command.ExecuteNonQueryAsync();
            }
            await f.Cache.InitializeAsync();
            Check((await f.Cache.GetPendingSendsAsync("route")).Single().TempId=="legacy","legacy migration");
        }
    }
    private static void Check(bool condition,string reason){if(!condition)throw new InvalidOperationException(reason);}
    private sealed class Fixture:IDisposable
    {
        public string Root {get;}=Path.Combine(Path.GetTempPath(),"micago-outgoing-"+Guid.NewGuid().ToString("N"));
        public string Database=>Path.Combine(Root,"cache.db");
        public LocalCacheStore Cache {get;}
        public FakeApi Api {get;}=new();
        public OutgoingSendService Sender {get;}
        public Fixture(){Directory.CreateDirectory(Root);Cache=new(Database);Sender=new(Api,Cache,new MediaCache(Path.Combine(Root,"media")),Path.Combine(Root,"pending"));}
        public void Dispose(){Sender.Dispose();Cache.Dispose();SqliteConnection.ClearAllPools();Directory.Delete(Root,true);}
    }
    private sealed class FakeApi:RealtimeSyncTests.FakeApi
    {
        public int TextCalls,FileCalls;public string? LastRoute,LastName;public bool LastVoice;public CancellationToken FileToken;
        public Func<string,string,string,Task<Message>> Text {get;set;}=(route,text,id)=>Task.FromResult(new Message("server-"+id,route,text,"",true,MessageDeliveryState.Sent,DateCreated:DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()));
        public Func<string,string,string,bool,IProgress<double>?,Task<AttachmentUploadResult>> File {get;set;}=(_,_,path,_,_)=>Task.FromResult(new AttachmentUploadResult(Path.GetFileName(path)));
        public override Task<Message> SendTextAsync(string chatId,string text,string? tempId=null,CancellationToken cancellationToken=default){TextCalls++;return Text(chatId,text,tempId!);}
        public override Task<AttachmentUploadResult> SendAttachmentAsync(string chatId,string tempId,string filePath,bool isAudioMessage=false,IProgress<double>? progress=null,CancellationToken cancellationToken=default)
        {FileCalls++;LastRoute=chatId;LastName=Path.GetFileName(filePath);LastVoice=isAudioMessage;FileToken=cancellationToken;return File(chatId,tempId,filePath,isAudioMessage,progress);}
    }
}

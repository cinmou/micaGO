using Microsoft.Data.Sqlite;
using MicaGo.Core.Models;
using MicaGo.Infrastructure.Api;
using MicaGo.Infrastructure.Connection;
using MicaGo.Infrastructure.Storage;

internal static class MessagePreferenceSyncTests
{
    private sealed class Server : RealtimeSyncTests.FakeApi
    {
        public string ServerId = new('a', 32);
        public bool Offline;
        public bool LoseReply;
        public long Revision;
        public readonly Dictionary<string,MessagePreference> Rows = [];
        private readonly Dictionary<string,MessagePreferences> _replies = [];
        public override Task<MessagePreferences> GetMessagePreferencesAsync(CancellationToken ct=default)
        {
            if(Offline)throw new HttpRequestException("offline\u001fm");
            return Task.FromResult(new MessagePreferences(ServerId,Revision,Rows.Values.ToArray()));
        }
        public override Task<MessagePreferences> PatchMessagePreferencesAsync(MessagePreferenceMutation request,CancellationToken ct=default)
        {
            if(Offline)throw new HttpRequestException("offline\u001fm");
            if(_replies.TryGetValue(request.MutationId,out var replay))return Task.FromResult(replay);
            if(request.ServerId!=ServerId||request.Changes.Any(change=>change.BaseRevision!=(Rows.GetValueOrDefault(change.MessageKey)?.Revision??0)))throw new MicaGoApiException("conflict\u001fm",409);
            Revision++;
            var data=request.Changes.Select(change=>new MessagePreference(change.MessageKey,change.Hidden,Revision)).ToArray();
            foreach(var row in data)Rows[row.MessageKey]=row;
            var reply=new MessagePreferences(ServerId,Revision,data);_replies[request.MutationId]=reply;
            if(LoseReply){LoseReply=false;throw new HttpRequestException("lost acknowledgement");}
            return Task.FromResult(reply);
        }
    }

    public static async Task RunAsync()
    {
        var directory=Directory.CreateTempSubdirectory("micago-preferences-");
        try
        {
            using var cacheA=new LocalCacheStore(Path.Combine(directory.FullName,"a.db"));
            using var cacheB=new LocalCacheStore(Path.Combine(directory.FullName,"b.db"));
            var server=new Server();var a=new MessagePreferenceSync(cacheA,()=>server);var b=new MessagePreferenceSync(cacheB,()=>server);
            await cacheA.InitializeAsync();
            await cacheA.HideMessagesAsync(["legacy\u001fm"]);
            await a.SyncAsync();await b.SyncAsync();
            True(a.LegacyCount==1&&server.Revision==0,"legacy records uploaded automatically");
            await a.ImportLegacyAsync();await b.SyncAsync();
            True(b.Hidden.Contains("legacy\u001fm"),"legacy import not synced");
            await a.SetHiddenAsync(["route-a\u001fm","route-b\u001fm"],true);await b.SyncAsync();
            True(b.Hidden.Contains("route-a\u001fm")&&b.Hidden.Contains("route-b\u001fm"),"route batch not synced");
            await b.SetHiddenAsync(["route-a\u001fm","route-b\u001fm"],false);await a.SyncAsync();
            True(!a.Hidden.Contains("route-a\u001fm"),"restore not synced");
            server.Offline=true;await a.SetHiddenAsync(["offline\u001fm"],true);await a.SetHiddenAsync(["offline\u001fm"],false);
            a=new MessagePreferenceSync(cacheA,()=>server);server.Offline=false;await a.SyncAsync();
            True(!a.Pending&&!a.HasConflicts&&!server.Rows["offline\u001fm"].Hidden,"restart lost offline ordering");
            server.LoseReply=true;await a.SetHiddenAsync(["lost\u001fm"],true);
            await b.SyncAsync();await b.SetHiddenAsync(["lost\u001fm"],false);var revision=server.Revision;await a.SyncAsync();
            True(!a.Pending&&!a.Hidden.Contains("lost\u001fm")&&server.Revision==revision,"replay overwrote a later edit");
            server.Offline=true;await a.SetHiddenAsync(["conflict\u001fm"],true);server.Offline=false;
            await b.SetHiddenAsync(["conflict\u001fm"],false);await a.SyncAsync();
            True(a.HasConflicts&&!a.Hidden.Contains("conflict\u001fm"),"stale write overwrote server");
            await a.ResolveConflictsAsync(true);await b.SyncAsync();
            True(!a.HasConflicts&&b.Hidden.Contains("conflict\u001fm"),"explicit conflict resolution failed");
            server.Offline=true;await a.SetHiddenAsync(["private-route\u001fm"],true);server.Offline=false;server.ServerId=new('b',32);
            await a.SyncAsync();True(!a.Pending&&!server.Rows.ContainsKey("private-route\u001fm"),"outbox crossed server identity");
            server.ServerId=new('a',32);await a.SyncAsync();True(server.Rows["private-route\u001fm"].Hidden,"archived outbox lost");
            var confirmed=new Message("server-guid","route-a","confirmed","",true,MessageDeliveryState.Sent,PresentationId:"local-temp");
            True(confirmed.ServerKey=="route-a\u001fserver-guid"&&confirmed.ServerKey!=confirmed.TimelineKey,"hiding used a presentation ID instead of server GUID");
            await a.SetHiddenAsync(["route-a\u001fsame-guid"], true);
            await a.SetHiddenAsync(["route-b\u001fsame-guid"], false);
            await b.SyncAsync();
            True(b.Hidden.Contains("route-a\u001fsame-guid") && !b.Hidden.Contains("route-b\u001fsame-guid"), "same GUID leaked across routes");
            var mirror=await cacheB.GetHiddenMessageKeysAsync();
            True(mirror.SetEquals(b.Hidden), "SQLite visibility disagrees with synchronized state");
            await cacheA.AdvanceReadWatermarkAsync("route-a",200);
            await cacheA.AdvanceReadWatermarkAsync("route-a",100);
            True(await cacheA.GetSettingAsync("read.watermark.route-a")=="200","older read event regressed watermark");
            await cacheA.ClearContentCacheAsync();True(await cacheA.GetSettingAsync("message.preferences.v1") is not null,"cache clear erased preferences");
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            directory.Delete(true);
        }
    }
    private static void True(bool condition,string message){if(!condition)throw new InvalidOperationException(message);}
}

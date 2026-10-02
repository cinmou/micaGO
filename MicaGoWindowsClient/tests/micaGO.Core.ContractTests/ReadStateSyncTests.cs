using System.Text.Json;
using Microsoft.Data.Sqlite;
using MicaGo.Core.Connection;
using MicaGo.Core.Models;
using MicaGo.Infrastructure.Api;
using MicaGo.Infrastructure.Connection;
using MicaGo.Infrastructure.Storage;

internal static class ReadStateSyncTests
{
    private sealed class Server:RealtimeSyncTests.FakeApi {
        public string Id=new('a',32);
        public bool Offline,LoseReply;
        private readonly Dictionary<string,Dictionary<string,long>> _servers=[];
        public Dictionary<string,long> Rows=>_servers.TryGetValue(Id,out var rows)?rows:(_servers[Id]=[]);
        public override Task<ReadState> GetReadStateAsync(CancellationToken ct=default) {
            if(Offline)throw new HttpRequestException("offline");
            return Task.FromResult(new ReadState(Id,0,Rows.Select(pair=>new ReadPosition(pair.Key,pair.Value)).ToArray()));
        }
        public override Task<ReadState> PatchReadStateAsync(ReadStateMutation mutation,CancellationToken ct=default) {
            if(Offline)throw new HttpRequestException("offline");
            if(mutation.ServerId!=Id)throw new MicaGoApiException("scope",409);
            foreach(var row in mutation.Changes)Rows[row.ChatGuid]=Math.Max(Rows.GetValueOrDefault(row.ChatGuid),row.ReadThrough);
            if(LoseReply){LoseReply=false;throw new HttpRequestException("lost acknowledgement");}
            return GetReadStateAsync(ct);
        }
    }
    public static async Task RunAsync() {
        var directory=Directory.CreateTempSubdirectory("micago-read-");
        try {
            using var cacheA=new LocalCacheStore(Path.Combine(directory.FullName,"a.db"));
            using var cacheB=new LocalCacheStore(Path.Combine(directory.FullName,"b.db"));
            var server=new Server();var a=new ReadStateSync(cacheA,()=>server);var b=new ReadStateSync(cacheB,()=>server);
            a.Changed+=(_,_)=>throw new InvalidOperationException("simulated UI refresh failure");
            await a.SyncAsync();await b.SyncAsync();await a.MarkViewedAsync(new Dictionary<string,long>{{"a",200},{"b",50}});await b.SyncAsync();
            True(await cacheB.GetSettingAsync("read.watermark.a")=="200","remote read not mirrored");
            await b.MarkViewedAsync(new Dictionary<string,long>{{"a",100}});True(server.Rows["a"]==200&&server.Rows["b"]==50,"read regressed or crossed routes");
            server.Offline=true;await a.MarkViewedAsync(new Dictionary<string,long>{{"a",300}});
            a=new ReadStateSync(cacheA,()=>server);server.Offline=false;server.LoseReply=true;await a.SyncAsync();await a.SyncAsync();
            True(server.Rows["a"]==300,"offline read lost after restart");
            using(var state=JsonDocument.Parse((await cacheA.GetSettingAsync("read.state.v1"))!))True(state.RootElement.GetProperty("Pending").EnumerateObject().Count()==0,"ack retry left outbox");
            server.Offline=true;await a.MarkViewedAsync(new Dictionary<string,long>{{"private",500}});server.Offline=false;
            server.Id=new('b',32);await a.SyncAsync();True(server.Rows.Count==0,"read outbox crossed server scope");
            server.Id=new('a',32);await a.SyncAsync();True(server.Rows["private"]==500,"archived read was lost");
            await cacheA.ClearContentCacheAsync();True(await cacheA.GetSettingAsync("read.state.v1") is not null,"cache clear erased read state");
            var profile=new ConnectionProfile("test","http://lan","ws://lan/ws",ConnectionMode.LanFirst,"old",[new(EndpointKind.Lan,"http://lan","ws://lan/ws"),new(EndpointKind.Public,"https://old","wss://old/ws")],"http://lan");
            using var endpoints=JsonDocument.Parse("""{"connectionRevision":"new","lan":[{"baseUrl":"http://lan","wsUrl":"ws://lan/updated","enabled":true}],"public":{"enabled":true,"baseUrl":"https://new","wsUrl":"wss://new/ws"}}""");
            var next=EndpointConfiguration.Apply(profile,endpoints.RootElement);
            True(next.ConfigRevision=="new"&&next.SelectedBaseUrl=="http://lan"&&next.Endpoints.Any(e=>e.BaseUrl=="https://new"),"endpoint refresh lost pin or public route");
            True(next.ActiveWebSocketUrl=="ws://lan/updated","websocket config not refreshed");
            using var changedLan=JsonDocument.Parse("""{"connectionRevision":"changed","lan":[{"baseUrl":"http://changed","hidden":false}],"public":{"enabled":true,"baseUrl":"https://new"}}""");
            var changed=EndpointConfiguration.Apply(next,changedLan.RootElement);
            True(changed.Endpoints.Any(e=>e.BaseUrl=="http://changed")&&changed.SelectedBaseUrl is null,"explicit visible replacement LAN was discarded");
            using var wake=JsonDocument.Parse("""{"connectionRevision":"wake","lan":[],"public":{"enabled":false}}""");
            var waking=EndpointConfiguration.Apply(next,wake.RootElement);True(waking.Endpoints.Any(e=>e.Kind==EndpointKind.Lan)&&!waking.Endpoints.Any(e=>e.Kind==EndpointKind.Public),"wake wiped LAN or retained disabled public route");
            using var hidden=JsonDocument.Parse("""{"connectionRevision":"hide","lan":[{"baseUrl":"http://lan","hidden":true}],"public":{"enabled":false}}""");
            var removed=EndpointConfiguration.Apply(next,hidden.RootElement);True(removed.Endpoints.Count==0&&removed.SelectedBaseUrl is null,"hidden endpoint or invalid pin survived");
        }
        finally {SqliteConnection.ClearAllPools();directory.Delete(true);}
    }
    private static void True(bool condition,string message){if(!condition)throw new InvalidOperationException(message);}
}

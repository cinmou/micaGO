using System.Text.Json;
using MicaGo.Core.Models;
using MicaGo.Infrastructure.Contracts;
using MicaGo.Infrastructure.Storage;
namespace MicaGo.Infrastructure.Connection;

public sealed class ReadStateSync(LocalCacheStore cache, Func<IMicaGoApi?> api)
{
    private const string Key = "read.state.v1";
    private readonly SemaphoreSlim _gate = new(1,1);
    private State _state = new();
    private bool _loaded;
    private string? _savedState;
    public IReadOnlyDictionary<string,long> Positions { get; private set; } = new Dictionary<string,long>();
    public event EventHandler? Changed;
    public sealed class State {
        public string? ServerId {get;set;}
        public Dictionary<string,long> Rows {get;set;} = [];
        public Dictionary<string,long> Pending {get;set;} = [];
    }
    private async Task LoadAsync(CancellationToken ct) {
        if(_loaded)return;
        var raw = await cache.GetSettingAsync(Key,ct);
        if(raw is not null)_state=JsonSerializer.Deserialize<State>(raw) ?? throw new InvalidDataException("Invalid read state.");
        _loaded=true;
    }
    private async Task PublishAsync(CancellationToken ct) {
        var encoded=JsonSerializer.Serialize(_state);
        if(encoded!=_savedState){await cache.SetSettingAsync(Key,encoded,ct);_savedState=encoded;}
        var positions = new Dictionary<string,long>(_state.Rows,StringComparer.Ordinal);
        foreach(var (route,at) in _state.Pending)positions[route]=Math.Max(positions.GetValueOrDefault(route),at);
        foreach(var (route,at) in positions)await cache.AdvanceReadWatermarkAsync(route,at,ct);
        var changed=positions.Count!=Positions.Count||positions.Any(pair=>!Positions.TryGetValue(pair.Key,out var at)||at!=pair.Value);
        Positions=positions;
        if(changed && Changed is {} observers) {
            foreach(EventHandler observer in observers.GetInvocationList()) {
                try {observer(this,EventArgs.Empty);}
                catch(Exception error) {System.Diagnostics.Debug.WriteLine($"[Read state] observer failed: {error.GetType().Name}");}
            }
        }
    }
    private void Apply(ReadState snapshot) {
        foreach(var row in snapshot.Data)_state.Rows[row.ChatGuid]=Math.Max(_state.Rows.GetValueOrDefault(row.ChatGuid),row.ReadThrough);
    }
    public async Task SyncAsync(CancellationToken ct=default) {
        await _gate.WaitAsync(ct);
        try {await LoadAsync(ct);await SyncInnerAsync(ct);}finally{_gate.Release();}
    }
    private async Task SyncInnerAsync(CancellationToken ct) {
        var client=api();if(client is null)return;
        try {
            var snapshot=await client.GetReadStateAsync(ct);
            if(!ReferenceEquals(client,api()))return;
            if(_state.ServerId is not null && _state.ServerId!=snapshot.ServerId) {
                await cache.SetSettingAsync(Key+"."+_state.ServerId,JsonSerializer.Serialize(_state),ct);
                var archived=await cache.GetSettingAsync(Key+"."+snapshot.ServerId,ct);
                _state=archived is null?new State():JsonSerializer.Deserialize<State>(archived)??throw new InvalidDataException("Invalid read state.");
            }
            _state.ServerId=snapshot.ServerId;Apply(snapshot);await PublishAsync(ct);
            while(_state.Pending.Count>0&&ReferenceEquals(client,api())) {
                var batch=_state.Pending.Take(200).Select(pair=>new ReadPosition(pair.Key,pair.Value)).ToArray();
                var reply=await client.PatchReadStateAsync(new(snapshot.ServerId,batch),ct);
                if(!ReferenceEquals(client,api())||reply.ServerId!=snapshot.ServerId)return;
                Apply(reply);
                foreach(var row in batch)if(_state.Rows.GetValueOrDefault(row.ChatGuid)>=row.ReadThrough)_state.Pending.Remove(row.ChatGuid);
                await PublishAsync(ct);
            }
        }
        catch(OperationCanceledException)when(ct.IsCancellationRequested){throw;}
        catch(OperationCanceledException) { }
        catch(HttpRequestException) { }
        catch(MicaGo.Infrastructure.Api.MicaGoApiException) { }
    }
    public async Task MarkViewedAsync(IReadOnlyDictionary<string,long> positions,CancellationToken ct=default) {
        var expected=api();
        await _gate.WaitAsync(ct);
        try {
            await LoadAsync(ct);var server=_state.ServerId;
            if(server is null)await SyncInnerAsync(ct);
            if(_state.ServerId is null||!ReferenceEquals(expected,api())||(server is not null&&server!=_state.ServerId))return;
            foreach(var (route,at) in positions)if(at>Math.Max(_state.Rows.GetValueOrDefault(route),_state.Pending.GetValueOrDefault(route)))_state.Pending[route]=at;
            if(_state.Pending.Count==0)return;
            await PublishAsync(ct);await SyncInnerAsync(ct);
        }finally{_gate.Release();}
    }
}

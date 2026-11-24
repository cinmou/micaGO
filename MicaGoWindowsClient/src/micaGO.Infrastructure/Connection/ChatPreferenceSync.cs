using System.Text.Json;
using MicaGo.Core.Models;
using MicaGo.Infrastructure.Api;
using MicaGo.Infrastructure.Contracts;
using MicaGo.Infrastructure.Storage;

namespace MicaGo.Infrastructure.Connection;

public sealed class ChatPreferenceSync(LocalCacheStore cache, Func<IMicaGoApi?> api)
{
    private const string Key = "chat.preferences.v1";
    private readonly SemaphoreSlim _gate = new(1, 1);
    private PreferenceState _state = new();
    private bool _loaded;
    private HashSet<string> _hidden = [];
    private string? _savedState;
    private string? _publishedError;
    public IReadOnlySet<string> Hidden => _hidden;
    public int LegacyCount => _state.Legacy.Count;
    public bool HasConflicts => _state.Conflicts.Count > 0;
    public bool Pending => _state.Queue.Count > 0;
    public string? ErrorKey { get; private set; }
    public event EventHandler? Changed;

    public sealed class PreferenceState
    {
        public string? ServerId { get; set; }
        public Dictionary<string, ChatPreference> Rows { get; set; } = [];
        public List<ChatPreferenceMutation> Queue { get; set; } = [];
        public List<ChatPreferenceMutation> Conflicts { get; set; } = [];
        public HashSet<string> Legacy { get; set; } = [];
    }

    private async Task LoadAsync(CancellationToken ct)
    {
        if (_loaded) return;
        var raw = await cache.GetSettingAsync(Key, ct);
        if (!string.IsNullOrEmpty(raw)) _state = JsonSerializer.Deserialize<PreferenceState>(raw) ?? throw new InvalidDataException("Invalid preference state.");
        else _state.Legacy = new HashSet<string>(await cache.GetHiddenChatGuidsAsync(ct), StringComparer.Ordinal);
        _loaded = true;
        await PublishAsync(ct);
    }

    private async Task PublishAsync(CancellationToken ct)
    {
        var hidden = new HashSet<string>(_state.Legacy, StringComparer.Ordinal);
        foreach (var row in _state.Rows.Values) if (row.Hidden) hidden.Add(row.ChatGuid);
        foreach (var mutation in _state.Queue)
            foreach (var change in mutation.Changes)
                if (change.Hidden) hidden.Add(change.ChatGuid); else hidden.Remove(change.ChatGuid);
        _hidden = hidden;
        var encoded = JsonSerializer.Serialize(_state);
        var changed = encoded != _savedState || ErrorKey != _publishedError;
        if(encoded != _savedState) {
            await cache.SetSettingAsync(Key, encoded, ct);
            _savedState = encoded;
        }
        _publishedError = ErrorKey;
        if(changed) Changed?.Invoke(this, EventArgs.Empty);
    }

    public async Task SyncAsync(CancellationToken ct = default)
    {
        await _gate.WaitAsync(ct);
        try { await LoadAsync(ct); await SyncInnerAsync(ct); }
        finally { _gate.Release(); }
    }

    private async Task SyncInnerAsync(CancellationToken ct)
    {
        var client = api();
        if (client is null) { ErrorKey = "prefsOffline"; await PublishAsync(ct); return; }
        try
        {
            var snapshot = await client.GetChatPreferencesAsync(ct);
            if (!ReferenceEquals(client, api())) return;
            if (_state.ServerId is not null && _state.ServerId != snapshot.ServerId)
            {
                await cache.SetSettingAsync(Key + "." + _state.ServerId, JsonSerializer.Serialize(_state), ct);
                var archived = await cache.GetSettingAsync(Key + "." + snapshot.ServerId, ct);
                _state = string.IsNullOrEmpty(archived) ? new PreferenceState() :
                    JsonSerializer.Deserialize<PreferenceState>(archived) ?? throw new InvalidDataException("Invalid preference state.");
            }
            _state.ServerId = snapshot.ServerId;
            _state.Rows = snapshot.Data.ToDictionary(row => row.ChatGuid, StringComparer.Ordinal);
            while (_state.Queue.Count > 0 && ReferenceEquals(client, api()))
            {
                var request = _state.Queue[0];
                try
                {
                    var reply = await client.PatchChatPreferencesAsync(request, ct);
                    _state.Queue.RemoveAt(0);
                    foreach (var row in reply.Data)
                    {
                        if (!_state.Rows.TryGetValue(row.ChatGuid, out var current) || current.Revision <= row.Revision) _state.Rows[row.ChatGuid] = row;
                        var matched = request.Changes.FirstOrDefault(change => change.ChatGuid == row.ChatGuid);
                        if (matched is not null)
                        {
                            var before = matched.BaseRevision;
                            for (var i = 0; i < _state.Queue.Count; i++)
                                _state.Queue[i] = _state.Queue[i] with { Changes = _state.Queue[i].Changes.Select(change =>
                                    change.ChatGuid == row.ChatGuid && change.BaseRevision == before ? change with { BaseRevision = row.Revision } : change).ToArray() };
                        }
                    }
                }
                catch (MicaGoApiException ex) when (ex.StatusCode == 409)
                {
                    var current = await client.GetChatPreferencesAsync(ct);
                    if(current.ServerId != _state.ServerId) throw new InvalidOperationException("Preference server changed.");
                    _state.Conflicts.Add(request);
                    _state.Queue.RemoveAt(0);
                    _state.Rows = current.Data.ToDictionary(row => row.ChatGuid, StringComparer.Ordinal);
                }
                await PublishAsync(ct);
            }
            ErrorKey = HasConflicts ? "prefsConflict" : null;
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch { ErrorKey = "prefsOffline"; }
        await PublishAsync(ct);
    }

    public async Task SetHiddenAsync(IEnumerable<string> guids, bool hidden, CancellationToken ct = default)
    {
        await _gate.WaitAsync(ct);
        try
        {
            await LoadAsync(ct);
            if (_state.ServerId is null) await SyncInnerAsync(ct);
            if (_state.ServerId is null) throw new InvalidOperationException("Connect once before syncing hidden chats.");
            var ids = guids.Distinct(StringComparer.Ordinal).ToArray();
            foreach (var batch in ids.Chunk(200))
                _state.Queue.Add(new(_state.ServerId, Guid.NewGuid().ToString("N"), batch.Select(guid =>
                    new ChatPreferenceChange(guid, hidden, _state.Rows.GetValueOrDefault(guid)?.Revision ?? 0)).ToArray()));
            _state.Legacy.ExceptWith(ids);
            await PublishAsync(ct);
            await SyncInnerAsync(ct);
        }
        finally { _gate.Release(); }
    }

    public Task ImportLegacyAsync(CancellationToken ct = default) => SetHiddenAsync(_state.Legacy.ToArray(), true, ct);
    public async Task ResolveConflictsAsync(bool useMine, CancellationToken ct = default)
    {
        var desired = new Dictionary<string, bool>(StringComparer.Ordinal);
        await _gate.WaitAsync(ct);
        try
        {
            await LoadAsync(ct);
            foreach (var change in _state.Conflicts.SelectMany(m => m.Changes)) desired[change.ChatGuid] = change.Hidden;
            if(useMine && _state.ServerId is {} server) {
                foreach(var batch in desired.Chunk(200))
                    _state.Queue.Add(new(server,Guid.NewGuid().ToString("N"),batch.Select(pair=>
                        new ChatPreferenceChange(pair.Key,pair.Value,_state.Rows.GetValueOrDefault(pair.Key)?.Revision??0)).ToArray()));
            }
            _state.Conflicts.Clear();
            ErrorKey = null;
            await PublishAsync(ct);
            if(useMine) await SyncInnerAsync(ct);
        }
        finally { _gate.Release(); }
    }
}

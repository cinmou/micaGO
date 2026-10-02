using System.Text.Json;
using MicaGo.Core.Models;
using MicaGo.Infrastructure.Api;
using MicaGo.Infrastructure.Contracts;
using MicaGo.Infrastructure.Storage;

namespace MicaGo.Infrastructure.Connection;

public sealed class MessagePreferenceSync(LocalCacheStore cache, Func<IMicaGoApi?> api)
{
    private const string Key = "message.preferences.v1";
    private readonly SemaphoreSlim _gate = new(1, 1);
    private PreferenceState _state = new();
    private bool _loaded;
    private HashSet<string> _hidden = [];
    private HashSet<string>? _mirrored;
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
        public Dictionary<string, MessagePreference> Rows { get; set; } = [];
        public List<MessagePreferenceMutation> Queue { get; set; } = [];
        public List<MessagePreferenceMutation> Conflicts { get; set; } = [];
        public HashSet<string> Legacy { get; set; } = [];
    }

    private async Task LoadAsync(CancellationToken ct)
    {
        if (_loaded) return;
        var raw = await cache.GetSettingAsync(Key, ct);
        if (!string.IsNullOrEmpty(raw)) _state = JsonSerializer.Deserialize<PreferenceState>(raw) ?? throw new InvalidDataException("Invalid preference state.");
        else {
            _state.Legacy = new HashSet<string>(await cache.GetHiddenMessageKeysAsync(ct), StringComparer.Ordinal);
            var rows = await cache.GetHiddenMessagesAsync(ct);
            foreach (var key in _state.Legacy.Where(key => !key.Contains('\u001f')).ToArray()) {
                var candidates = rows.Where(row => row.Id == key).Select(row => row.ServerKey).Distinct().ToArray();
                if (candidates.Length == 1) { _state.Legacy.Remove(key); _state.Legacy.Add(candidates[0]); }
            }
        }
        _loaded = true;
        await PublishAsync(ct);
    }

    private async Task PublishAsync(CancellationToken ct)
    {
        var hidden = new HashSet<string>(_state.Legacy, StringComparer.Ordinal);
        foreach (var row in _state.Rows.Values) if (row.Hidden) hidden.Add(row.MessageKey);
        foreach (var mutation in _state.Queue)
            foreach (var change in mutation.Changes)
                if (change.Hidden) hidden.Add(change.MessageKey); else hidden.Remove(change.MessageKey);
        _hidden = hidden;
        if (_mirrored is null || !_mirrored.SetEquals(hidden)) {
            await cache.ApplyMessageVisibilityAsync(hidden, ct);
            _mirrored = new HashSet<string>(hidden, StringComparer.Ordinal);
        }
        var encoded = JsonSerializer.Serialize(_state);
        var changed = encoded != _savedState || ErrorKey != _publishedError;
        if(encoded != _savedState) {
            await cache.SetSettingAsync(Key, encoded, ct);
            _savedState = encoded;
        }
        _publishedError = ErrorKey;
        if(changed && Changed is {} subscribers) {
            foreach(EventHandler observer in subscribers.GetInvocationList()) {
                try {observer(this,EventArgs.Empty);}
                catch(Exception error) {System.Diagnostics.Debug.WriteLine($"[Message preferences] observer failed: {error.GetType().Name}");}
            }
        }
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
            var snapshot = await client.GetMessagePreferencesAsync(ct);
            if (!ReferenceEquals(client, api())) return;
            if (_state.ServerId is not null && _state.ServerId != snapshot.ServerId)
            {
                await cache.SetSettingAsync(Key + "." + _state.ServerId, JsonSerializer.Serialize(_state), ct);
                var archived = await cache.GetSettingAsync(Key + "." + snapshot.ServerId, ct);
                _state = string.IsNullOrEmpty(archived) ? new PreferenceState() :
                    JsonSerializer.Deserialize<PreferenceState>(archived) ?? throw new InvalidDataException("Invalid preference state.");
            }
            _state.ServerId = snapshot.ServerId;
            _state.Rows = snapshot.Data.ToDictionary(row => row.MessageKey, StringComparer.Ordinal);
            while (_state.Queue.Count > 0 && ReferenceEquals(client, api()))
            {
                var request = _state.Queue[0];
                try
                {
                    var reply = await client.PatchMessagePreferencesAsync(request, ct);
                    _state.Queue.RemoveAt(0);
                    foreach (var row in reply.Data)
                    {
                        if (!_state.Rows.TryGetValue(row.MessageKey, out var current) || current.Revision <= row.Revision) _state.Rows[row.MessageKey] = row;
                        var before = request.Changes.First(change => change.MessageKey == row.MessageKey).BaseRevision;
                        for (var i = 0; i < _state.Queue.Count; i++)
                            _state.Queue[i] = _state.Queue[i] with { Changes = _state.Queue[i].Changes.Select(change =>
                                change.MessageKey == row.MessageKey && change.BaseRevision == before ? change with { BaseRevision = row.Revision } : change).ToArray() };
                    }
                }
                catch (MicaGoApiException ex) when (ex.StatusCode == 409)
                {
                    var current = await client.GetMessagePreferencesAsync(ct);
                    if(current.ServerId != _state.ServerId) throw new InvalidOperationException("Preference server changed.");
                    _state.Conflicts.Add(request);
                    _state.Queue.RemoveAt(0);
                    _state.Rows = current.Data.ToDictionary(row => row.MessageKey, StringComparer.Ordinal);
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
            if (_state.ServerId is null) throw new InvalidOperationException("Connect once before syncing hidden messages.");
            var requested = guids.Distinct(StringComparer.Ordinal).ToArray();
            if (!hidden) {
                foreach (var key in requested) {
                    _state.Legacy.Remove(key);
                    if (key.Contains('\u001f')) _state.Legacy.Remove(key.Split('\u001f')[1]);
                }
            }
            var ids = requested.Where(key => key.Split('\u001f') is [ { Length: > 0 }, { Length: > 0 } ]).ToArray();
            foreach (var batch in ids.Chunk(200))
                _state.Queue.Add(new(_state.ServerId, Guid.NewGuid().ToString("N"), batch.Select(guid =>
                    new MessagePreferenceChange(guid, hidden, _state.Rows.GetValueOrDefault(guid)?.Revision ?? 0)).ToArray()));
            _state.Legacy.ExceptWith(ids);
            await PublishAsync(ct);
            await SyncInnerAsync(ct);
        }
        finally { _gate.Release(); }
    }

    public async Task RegisterLocalRecordsAsync(CancellationToken ct = default)
    {
        await _gate.WaitAsync(ct);
        try {
            var imported = await cache.GetHiddenMessageKeysAsync(ct);
            await LoadAsync(ct);
            _state.Legacy.UnionWith(imported.Except(_hidden));
            await PublishAsync(ct);
        }
        finally { _gate.Release(); }
    }

    public Task ImportLegacyAsync(CancellationToken ct = default) => SetHiddenAsync(_state.Legacy.Where(key => key.Contains('\u001f')).ToArray(), true, ct);
    public async Task ResolveConflictsAsync(bool useMine, CancellationToken ct = default)
    {
        var desired = new Dictionary<string, bool>(StringComparer.Ordinal);
        await _gate.WaitAsync(ct);
        try
        {
            await LoadAsync(ct);
            foreach (var change in _state.Conflicts.SelectMany(m => m.Changes)) desired[change.MessageKey] = change.Hidden;
            if(useMine && _state.ServerId is {} server) {
                foreach(var batch in desired.Chunk(200))
                    _state.Queue.Add(new(server,Guid.NewGuid().ToString("N"),batch.Select(pair=>
                        new MessagePreferenceChange(pair.Key,pair.Value,_state.Rows.GetValueOrDefault(pair.Key)?.Revision??0)).ToArray()));
            }
            _state.Conflicts.Clear();
            ErrorKey = null;
            await PublishAsync(ct);
            if(useMine) await SyncInnerAsync(ct);
        }
        finally { _gate.Release(); }
    }
}

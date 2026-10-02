using MicaGo.Core.Models;
using MicaGo.Infrastructure.Contracts;
using MicaGo.Infrastructure.Storage;

namespace MicaGo.Infrastructure.Connection;

public sealed record RealtimeMessageBatch(IReadOnlyList<Message> Messages, bool AllowNotifications);

public sealed class RealtimeSyncService(
    IMicaGoApi api,
    LocalCacheStore cache,
    ChatPreferenceSync? preferences = null,
    Func<CancellationToken, Task>? reselectRoute = null,
    MessagePreferenceSync? messagePreferences = null,
    ReadStateSync? readState = null,
    Func<CancellationToken,Task>? refreshEndpoints = null) : IAsyncDisposable
{
    private const string CursorKey = "sync.cursor";
    private readonly CancellationTokenSource _shutdown = new();
    private readonly SemaphoreSlim _catchUpGate = new(1, 1);
    private Task? _loop;

    public event EventHandler<RealtimeMessageBatch>? MessagesChanged;
    public event EventHandler<string>? StatusChanged;
    public event EventHandler<MessageActionCapabilities>? CapabilitiesChanged;

    public void Start()
    {
        if (_loop is null) _loop = Task.Run(() => RunAsync(_shutdown.Token));
    }

    public async Task CatchUpAsync(CancellationToken cancellationToken = default, bool allowNotifications = true)
    {
        await _catchUpGate.WaitAsync(cancellationToken);
        try
        {
            if(preferences is not null) await preferences.SyncAsync(cancellationToken);
            if(messagePreferences is not null) await messagePreferences.SyncAsync(cancellationToken);
            if(readState is not null) await readState.SyncAsync(cancellationToken);
            var raw = await cache.GetSettingAsync(CursorKey, cancellationToken);
            long? cursor = long.TryParse(raw, out var parsed) ? parsed : null;
            do
            {
                var delta = await api.GetMessagesDeltaAsync(cursor, cancellationToken: cancellationToken);
                cursor = delta.Cursor;
                if (delta.Messages.Count > 0)
                {
                    await cache.UpsertMessagesAsync(delta.Messages, cancellationToken);
                }
                // Persist rows before advancing the recovery cursor. A failed
                // cache write must leave this page eligible for replay.
                await cache.SetSettingAsync(CursorKey, delta.Cursor.ToString(), cancellationToken);
                if (delta.Messages.Count > 0)
                    MessagesChanged?.Invoke(this, new RealtimeMessageBatch(delta.Messages, allowNotifications));
                if (!delta.HasMore) break;
            } while (!cancellationToken.IsCancellationRequested);
        }
        finally { _catchUpGate.Release(); }
    }

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        var attempt = 0;
        var completedInitialCatchUp = false;
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                if(refreshEndpoints is not null) await refreshEndpoints(cancellationToken);
                await RefreshCapabilitiesAsync(cancellationToken);
                StatusChanged?.Invoke(this, "Catching up");
                // The first delta pass can contain everything accumulated while
                // the app was closed (or the complete history when no cursor is
                // stored). Cache and render it, but never surface it as a new
                // Windows notification. Reconnect catch-up after this point is
                // eligible because those messages arrived during this run.
                await CatchUpAsync(cancellationToken, completedInitialCatchUp);
                completedInitialCatchUp = true;
                StatusChanged?.Invoke(this, "Live");
                attempt = 0;
                await foreach (var realtimeEvent in api.ListenRealtimeAsync(cancellationToken))
                {
                    if(realtimeEvent.Type=="capabilities:updated") {
                        await RefreshCapabilitiesAsync(cancellationToken);
                    }
                    if(realtimeEvent.Type=="connection:updated" && refreshEndpoints is not null) await refreshEndpoints(cancellationToken);
                    // Frames that carry the full message JSON apply immediately —
                    // read receipts and edits update rows the rowid-based delta
                    // cursor never re-surfaces.
                    if (realtimeEvent.Message is { } message)
                    {
                        if(readState is not null)await readState.SyncAsync(cancellationToken);
                        if(messagePreferences is not null)await messagePreferences.SyncAsync(cancellationToken);
                        await cache.UpsertMessagesAsync([message], cancellationToken);
                        MessagesChanged?.Invoke(this, new RealtimeMessageBatch([message], true));
                    }
                    await CatchUpAsync(cancellationToken);
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { break; }
            catch
            {
                attempt++;
                StatusChanged?.Invoke(this, "Reconnecting");
                // W-UI9: re-run route selection before reconnecting, so a dropped
                // route falls back to another one (a manual switch also lands
                // here, through the cancelled socket).
                if (reselectRoute is not null)
                {
                    try { await reselectRoute(cancellationToken); }
                    catch when (!cancellationToken.IsCancellationRequested) { }
                }
                var delay = TimeSpan.FromSeconds(Math.Min(30, Math.Pow(2, Math.Min(attempt, 5))));
                try { await Task.Delay(delay, cancellationToken); } catch (OperationCanceledException) { break; }
            }
        }
    }

    private async Task RefreshCapabilitiesAsync(CancellationToken cancellationToken) {
        try {
            var capabilities=await api.GetMessageActionCapabilitiesAsync(cancellationToken);
            CapabilitiesChanged?.Invoke(this,capabilities);
        }
        catch(OperationCanceledException) when(cancellationToken.IsCancellationRequested) {throw;}
        catch(OperationCanceledException) { }
        catch(HttpRequestException) { }
        catch(MicaGo.Infrastructure.Api.MicaGoApiException) { }
    }

    public async ValueTask DisposeAsync()
    {
        _shutdown.Cancel();
        if (_loop is not null) { try { await _loop; } catch (OperationCanceledException) { } }
        _shutdown.Dispose(); _catchUpGate.Dispose();
    }
}

package app

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"micagoserver/internal/config"
	"micagoserver/internal/httpapi"
	"micagoserver/internal/imessage"
	"micagoserver/internal/notify"
	"micagoserver/internal/realtime"
	"micagoserver/internal/relaydb"
	micasend "micagoserver/internal/send"
	"micagoserver/internal/store"
	"micagoserver/internal/version"
)

type Options struct {
	SyncOnce        bool
	SyncInterval    string
	DisableSyncLoop bool
	Addr            string
	Token           string
	DisableAuth     bool
	PublicURL       string
}

type syncDiagnostics struct {
	mu   sync.Mutex
	data store.ServerSyncDiagnostics
}

func (d *syncDiagnostics) snapshot(pendingSends, pendingTriggers int) store.ServerSyncDiagnostics {
	d.mu.Lock()
	defer d.mu.Unlock()
	out := d.data
	out.PendingSendsCount = pendingSends
	out.PendingTriggerCount = pendingTriggers
	return out
}

func (d *syncDiagnostics) recordLockRetry() {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.data.LockRetryCount++
}

func (d *syncDiagnostics) recordRun(start time.Time, result relaydb.SyncResult) {
	d.mu.Lock()
	defer d.mu.Unlock()
	started := start.UnixMilli()
	completed := time.Now().UnixMilli()
	d.data.LastStartedAt = &started
	d.data.LastCompletedAt = &completed
	d.data.LastDurationMillis = completed - started
	d.data.LastInsertedMessages = len(result.NewMessages)
	d.data.LastSyncedMessages = result.MessagesSynced
	d.data.LastRowsScanned = result.RowsScanned
	d.data.LastRenderableRows = result.RenderableRowsInserted
	d.data.LastHiddenDebugRows = result.DebugOnlyRowsHidden
	d.data.LastPerChatLimit = result.PerChatLimit
	d.data.LastBackfillMode = result.Mode
	d.data.LastUpdatePassCount = len(result.Updates)
	d.data.LastUpdatePassSeeded = result.UpdateSeeded
	d.data.LastUnsentCount = len(result.Unsent)
	d.data.LastScannedMessageRowID = result.NewLastMessageRowID
	d.data.LastChatsWritten = result.ChatsWritten
	d.data.LastMessagesWritten = result.MessagesWritten
	d.data.LastAttachmentsWritten = result.AttachmentsWritten
	d.data.LastRowsUnchanged = result.ChatsUnchanged + result.MessagesUnchanged + result.AttachmentsUnchanged
	d.data.LastLookbackApplied = result.LookbackApplied
	d.data.LastSyncError = ""
}

func (d *syncDiagnostics) recordLateMatches(count int) {
	if count <= 0 {
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	d.data.LateMatchedSendsCount += count
}

func (d *syncDiagnostics) recordEvent(eventType string, chatGUID *string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.data.LastEmittedEventType = eventType
	d.data.LastEmittedChatGUID = chatGUID
}

func (d *syncDiagnostics) recordTrigger(reason string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.data.LastTriggerReason = reason
}

func (d *syncDiagnostics) recordDBMtime(chatDB, wal, shm *int64) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.data.LastChatDBMtime = chatDB
	d.data.LastWALMtime = wal
	d.data.LastSHMMtime = shm
}

func (d *syncDiagnostics) recordError(err error) {
	if err == nil {
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	d.data.LastSyncError = err.Error()
}

// lookbackScanEvery is how often the date-window recovery scan runs (C57). The
// rowid watermark catches new rows on every sync; the date union only recovers
// rows a WAL/rowid race skipped, so once a minute keeps the recovery bound
// tight while removing it from the 5s/mtime/send-burst hot path.
const lookbackScanEvery = time.Minute

// lookbackGate throttles the date-window recovery scan. take reports whether a
// scan is due and consumes the slot; rearm gives the slot back (used when the
// sync that consumed it failed, so recovery isn't delayed a full period).
type lookbackGate struct {
	mu      sync.Mutex
	every   time.Duration
	lastRun time.Time
}

func newLookbackGate(every time.Duration) *lookbackGate {
	return &lookbackGate{every: every}
}

func (g *lookbackGate) take(now time.Time) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if !g.lastRun.IsZero() && now.Sub(g.lastRun) < g.every {
		return false
	}
	g.lastRun = now
	return true
}

func (g *lookbackGate) rearm() {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.lastRun = time.Time{}
}

func Run(options Options) error {
	// C17: log the exact build identity first, so any log capture (including the
	// companion's) proves which binary is actually running.
	log.Printf("%s", version.String())
	if exe, err := os.Executable(); err == nil {
		log.Printf("executable: %s", exe)
	}

	cfg, err := config.Load(config.Options{
		Addr:            options.Addr,
		Token:           options.Token,
		DisableAuth:     options.DisableAuth,
		PublicURL:       options.PublicURL,
		SyncInterval:    options.SyncInterval,
		DisableSyncLoop: options.DisableSyncLoop,
		SyncOnce:        options.SyncOnce,
	})
	if err != nil {
		return err
	}
	if err := config.ValidateSecurity(cfg); err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	if cfg.FirstRun {
		log.Printf("created config file: %s", cfg.ConfigPath)
		log.Printf("first-run auth token: %s", cfg.AuthToken)
	}
	if !config.IsLocalAddress(cfg.HTTPAddr) {
		log.Printf("warning: binding to non-local address %s; ensure your network exposure and auth settings are intentional", cfg.HTTPAddr)
	}
	if config.IsWildcardAddress(cfg.HTTPAddr) {
		log.Printf("warning: %s listens on all interfaces", cfg.HTTPAddr)
	}

	db, err := store.OpenReadOnly(cfg.DBPath)
	if err != nil {
		return fmt.Errorf("open chat.db: %w", err)
	}
	defer db.Close()

	queries := store.NewQueries(db)
	relay, err := relaydb.Open(cfg.RelayDBPath)
	if err != nil {
		return fmt.Errorf("open relay.db: %w", err)
	}
	defer relay.Close()

	// Probe chat.db schema once so the update pass and status diagnostics know
	// which version-sensitive columns are available (v0.11.x).
	capabilities, err := store.ProbeCapabilities(ctx, db)
	if err != nil {
		log.Printf("chat.db schema probe failed (capabilities default to false): %v", err)
	} else {
		log.Printf("chat.db capabilities: %+v", capabilities)
	}

	// Probe the chat.db `message` columns once so the sync + debug reads can
	// select BlueBubbles-compatible semantic columns only when present. Wired
	// before the first sync so initial messages carry the new fields too.
	messageColumns, err := store.ProbeMessageColumns(ctx, db)
	if err != nil {
		log.Printf("chat.db message-column probe failed (semantic fields disabled): %v", err)
	}
	queries.SetMessageColumns(messageColumns)

	log.Printf("relay.db path: %s", cfg.RelayDBPath)
	hub := realtime.NewHub()
	defer hub.Close()
	dispatcher := notify.NewDispatcher(cfg)
	pendingSends := micasend.NewPendingSendManager()
	diagnostics := &syncDiagnostics{}
	// v0.12: prune dead FCM tokens reported by Google (clears the device's token).
	dispatcher.SetPruneFunc(func(id string) {
		if err := relay.ClearDevicePushToken(context.Background(), id); err != nil {
			log.Printf("prune push token for device %s: %v", id, err)
		}
	})
	// v0.12: optional Firestore public-URL sync at startup (when enabled+set).
	if cfg.Firebase.PublicURLSync && strings.TrimSpace(cfg.PublicBaseURL) != "" {
		dispatcher.SyncPublicURL(ctx, cfg.PublicBaseURL)
	}
	var syncMu sync.Mutex
	// C57: the date-window recovery scan re-reads (and used to re-upsert) up to
	// InitialSyncLimit rows of the lookback window on EVERY trigger — periodic
	// 5s ticks, sub-second WAL mtime hits, and 12-shot send bursts alike. The
	// rowid watermark is the primary new-message path and runs every sync; the
	// date union is only a recovery net for WAL/rowid races, so it runs at most
	// once per lookbackScanEvery (re-armed if the run fails).
	lookbackScan := newLookbackGate(lookbackScanEvery)
	runSync := func(ctx context.Context) (relaydb.SyncResult, error) {
		syncMu.Lock()
		defer syncMu.Unlock()
		start := time.Now()
		syncLookback := time.Duration(0)
		if lookbackScan.take(start) {
			syncLookback = cfg.UpdateLookback
		}
		result, err := relaydb.SyncOnce(ctx, queries, relay, cfg.InitialSyncLimit, syncLookback)
		if err != nil {
			if syncLookback > 0 {
				lookbackScan.rearm()
			}
			return result, err
		}
		// v0.11.x: bounded lookback update pass for old-row changes. Non-fatal;
		// new-message sync results are still returned on update-pass failure.
		updates, upErr := relaydb.UpdatePass(ctx, queries, relay, capabilities, cfg.UpdateLookback)
		if upErr != nil {
			log.Printf("update pass failed: %v", upErr)
		} else {
			result.Updates = updates.Updates
			result.Unsent = updates.Unsent
			result.UpdateScanned = updates.Scanned
			result.UpdateSeeded = updates.Seeded
		}
		diagnostics.recordRun(start, result)
		return result, nil
	}
	syncAndBroadcast := func(ctx context.Context, reason string) (relaydb.SyncResult, error) {
		diagnostics.recordTrigger(reason)
		result, err := runSync(ctx)
		if err != nil {
			diagnostics.recordError(err)
			return result, err
		}
		lateMatches := pendingSends.ReconcileMessages(sendCandidates(result.NewMessages), time.Now())
		if len(lateMatches) > 0 {
			diagnostics.recordLateMatches(len(lateMatches))
		}
		broadcastSyncResult(ctx, hub, result, diagnostics)
		for _, match := range lateMatches {
			for _, message := range result.NewMessages {
				if message.GUID == match.MatchedGUID {
					broadcastSendMatch(ctx, hub, match.TempGUID, message, diagnostics)
					pendingSends.Remove(match.TempGUID)
					break
				}
			}
		}
		dispatchNotifications(ctx, dispatcher, relay, result)
		return result, nil
	}

	if cfg.SyncOnce {
		result, err := runSync(ctx)
		if err != nil {
			return err
		}

		logSyncResult(result, true)
		return nil
	}

	// The startup sync is best-effort: a transient or data-shaped chat.db read
	// error must NOT take the whole HTTP API down (Sync Control, Paired Devices,
	// chats all read the cached relay.db and stay useful). We log the failure and
	// record it in the sync diagnostics (surfaced in the UI as lastSyncError);
	// the periodic + mtime sync loops keep retrying. Not swallowed — logged loudly.
	startupSync, err := syncAndBroadcast(ctx, "startup")
	if err != nil {
		log.Printf("startup sync failed (serving cached relay.db; will retry): %v", err)
	} else {
		logSyncResult(startupSync, true)
	}

	// C11: a single coalescing sync engine consumes all background triggers so a
	// burst of WAL/mtime/send triggers never piles up (and never gets dropped).
	// Direct callers (startup, client request, the immediate post-send sync) keep
	// running through runSync's mutex, so nothing overlaps.
	engine := NewSyncEngine(func(ctx context.Context, reason string) error {
		_, err := syncAndBroadcast(ctx, reason)
		return err
	})
	engine.onLockRetry = diagnostics.recordLockRetry
	engine.Start(ctx)

	if !cfg.DisableSyncLoop {
		interval := cfg.SyncInterval
		if interval <= 0 {
			interval = 5 * time.Second
		}
		go runSyncLoop(ctx, interval, func(ctx context.Context) (relaydb.SyncResult, error) {
			engine.Trigger("periodic")
			return relaydb.SyncResult{}, nil
		}, hub)
		go runDBMtimeSyncLoop(ctx, cfg.DBPath, 750*time.Millisecond, diagnostics, func(ctx context.Context) (relaydb.SyncResult, error) {
			engine.Trigger("chatdb_mtime")
			return relaydb.SyncResult{}, nil
		})
	}

	sendDeps := &httpapi.SendDependencies{
		Pending: pendingSends,
		Sender:  micasend.AppleScriptSender{},
		SyncNow: func(ctx context.Context) error {
			// Immediate sync so the send handler can poll fresh chat.db state,
			// plus a short coalesced burst so a delayed outgoing DB row (chat.db
			// write lag) is picked up within a few seconds.
			_, err := syncAndBroadcast(ctx, "send")
			engine.TriggerBurst(context.WithoutCancel(ctx), "send_burst", 12, 1500*time.Millisecond)
			return err
		},
		Events: hub,
		// Send-error fast-fail reads message.error from chat.db directly (the
		// relay schema has no error column), so it works in both api-store modes.
		ErrorFinder: queries,
		// Fast precondition: Messages.app must be running for AppleScript send.
		MessagesRunning: micasend.MessagesRunning,
	}

	netController := httpapi.NewNetworkController(cfg)
	// v0.12: when the public URL changes, sync it to Firestore (if enabled).
	netController.SetOnChange(func(ctx context.Context, publicURL string) {
		dispatcher.SyncPublicURL(ctx, publicURL)
	})

	// C17: backend identity for /api/server/status — lets the companion (and
	// curl) verify the launched binary is the intended build and that chat.db is
	// opened without immutable=1.
	executablePath := "unknown"
	if exe, exeErr := os.Executable(); exeErr == nil {
		executablePath = exe
	}
	chatDBOpenOptions := store.ChatDBOpenOptions()
	backendStatus := &store.ServerBackendStatus{
		Version:           version.Version,
		Commit:            version.ResolvedCommit(),
		BuildTime:         version.ResolvedBuildTime(),
		GoVersion:         version.GoVersion(),
		OSArch:            version.OSArch(),
		ExecutablePath:    executablePath,
		ConfigPath:        cfg.ConfigPath,
		RelayDBPath:       cfg.RelayDBPath,
		ChatDBPath:        cfg.DBPath,
		ChatDBOpenOptions: chatDBOpenOptions,
		ChatDBImmutable:   strings.Contains(chatDBOpenOptions, "immutable"),
	}

	statusDeps := httpapi.StatusDeps{
		APIStore:     "relaydb",
		ClientCount:  hub.ClientCount,
		Connections:  hub.Clients,
		SyncState:    relay.GetSyncState,
		Network:      netController,
		Capabilities: capabilities,
		SyncDiagnostics: func() store.ServerSyncDiagnostics {
			return diagnostics.snapshot(pendingSends.PendingCount(), engine.PendingCount())
		},
		Backend: backendStatus,
		SyncSettings: func(ctx context.Context) *store.ServerSyncSettings {
			s, err := relay.GetSyncSettings(ctx)
			if err != nil {
				return nil
			}
			return &store.ServerSyncSettings{
				BackfillMode:          s.BackfillMode,
				RecentMessagesPerChat: s.RecentMessagesPerChat,
				IncludeIMessage:       s.IncludeIMessage,
				IncludeSMS:            s.IncludeSMS,
				IncludeRCS:            s.IncludeRCS,
				IncludeUnknown:        s.IncludeUnknown,
				IncludeDebugInNormal:  s.IncludeDebugInNormal,
				AllowSMSSend:          s.AllowSMSSend,
			}
		},
	}

	handlers := httpapi.NewHandlers(relay, log.Default(), sendDeps, relay, cfg.AttachmentsRoot, relay, dispatcher, cfg, statusDeps)
	handlers.SetRuleService(relay)                   // v0.11.3 sync rules backed by relay.db
	handlers.SetTestContactService(relay)            // offline loopback test contact
	// Each server (re)start resets the test conversation to a clean scratchpad.
	if enabled, terr := relay.TestContactEnabled(ctx); terr == nil && enabled {
		if rerr := relay.ResetTestContactMessages(ctx); rerr != nil {
			log.Printf("reset test contact messages: %v", rerr)
		}
	}
	handlers.SetSyncSettingsService(relay)           // C13 service scope + backfill strategy
	handlers.SetNotificationConfigurator(dispatcher) // v0.12 live FCM/Firebase config
	handlers.SetMessageActionPerformer(imessage.NewHelperPerformer(""))
	handlers.SetSyncNow(func(ctx context.Context) (store.ServerSyncDiagnostics, error) {
		if _, err := syncAndBroadcast(ctx, "client_request"); err != nil {
			return store.ServerSyncDiagnostics{}, err
		}
		return diagnostics.snapshot(pendingSends.PendingCount(), engine.PendingCount()), nil
	})

	// Message inspector (debug): always backed by the live chat.db so it can
	// surface iMessage fields the synced relay does not keep. Reuses the probed
	// `message` column set. Auth-protected at the router.
	handlers.SetDebugService(queries, messageColumns)

	handler := httpapi.NewRouter(
		handlers,
		hub,
		httpapi.AuthConfig{
			Enabled: !cfg.AuthDisabled,
			Token:   cfg.AuthToken,
			Logger:  log.Default(),
		},
	)

	srv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()

	log.Printf("api-store: relaydb (single canonical path)")
	log.Printf("listening on http://%s", cfg.HTTPAddr)
	go func() {
		timer := time.NewTimer(500 * time.Millisecond)
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
			_ = hub.Broadcast(ctx, realtime.Event{
				Type: "connection:updated",
				Data: map[string]any{"reason": "startup"},
			})
		}
	}()

	err = srv.ListenAndServe()
	if err != nil && err != http.ErrServerClosed {
		if errors.Is(err, syscall.EADDRINUSE) {
			log.Printf("failed to bind %s: address already in use; check which process is listening with: lsof -nP -iTCP:3000 -sTCP:LISTEN", cfg.HTTPAddr)
		}
		return err
	}

	return nil
}

func sendCandidates(messages []store.MessageJSON) []micasend.ReconcileCandidate {
	out := make([]micasend.ReconcileCandidate, 0, len(messages))
	for _, message := range messages {
		chatGUID := ""
		if message.ChatGUID != nil {
			chatGUID = *message.ChatGUID
		}
		text := ""
		if message.Text != nil {
			text = *message.Text
		}
		out = append(out, micasend.ReconcileCandidate{
			GUID:        message.GUID,
			ChatGUID:    chatGUID,
			Text:        text,
			DateCreated: message.DateCreated,
			IsFromMe:    message.IsFromMe,
		})
	}
	return out
}

func runSyncLoop(
	ctx context.Context,
	interval time.Duration,
	syncNow func(context.Context) (relaydb.SyncResult, error),
	hub *realtime.Hub,
) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			result, err := syncNow(ctx)
			if err != nil {
				log.Printf("periodic sync failed: %v", err)
				if hub != nil {
					_ = hub.Broadcast(ctx, realtime.Event{
						Type: "sync:error",
						Data: map[string]any{
							"message": "periodic sync failed",
						},
					})
				}
				continue
			}
			logSyncResult(result, false)
		}
	}
}

func runDBMtimeSyncLoop(
	ctx context.Context,
	dbPath string,
	interval time.Duration,
	diagnostics *syncDiagnostics,
	syncNow func(context.Context) (relaydb.SyncResult, error),
) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	var lastChatDB, lastWAL, lastSHM int64
	chatDB, wal, shm := messageDBMtimes(dbPath)
	if chatDB != nil {
		lastChatDB = *chatDB
	}
	if wal != nil {
		lastWAL = *wal
	}
	if shm != nil {
		lastSHM = *shm
	}
	if diagnostics != nil {
		diagnostics.recordDBMtime(chatDB, wal, shm)
	}

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			chatDB, wal, shm := messageDBMtimes(dbPath)
			if diagnostics != nil {
				diagnostics.recordDBMtime(chatDB, wal, shm)
			}
			chatChanged := chatDB != nil && *chatDB > lastChatDB
			walChanged := wal != nil && *wal > lastWAL
			shmChanged := shm != nil && *shm > lastSHM
			if chatDB != nil {
				lastChatDB = *chatDB
			}
			if wal != nil {
				lastWAL = *wal
			}
			if shm != nil {
				lastSHM = *shm
			}
			if !chatChanged && !walChanged && !shmChanged {
				continue
			}
			if _, err := syncNow(ctx); err != nil {
				log.Printf("chat.db mtime sync failed: %v", err)
				if diagnostics != nil {
					diagnostics.recordError(err)
				}
			}
		}
	}
}

func messageDBMtimes(dbPath string) (*int64, *int64, *int64) {
	return fileMtimeMillis(dbPath), fileMtimeMillis(dbPath + "-wal"), fileMtimeMillis(dbPath + "-shm")
}

func fileMtimeMillis(path string) *int64 {
	info, err := os.Stat(path)
	if err != nil {
		return nil
	}
	v := info.ModTime().UnixMilli()
	return &v
}

func broadcastSyncResult(ctx context.Context, hub *realtime.Hub, result relaydb.SyncResult, diagnostics *syncDiagnostics) {
	if hub == nil {
		return
	}
	// C12: the realtime timeline is renderable-only. Debug-only/noise rows are
	// persisted (the Inspector reads them) but are never broadcast as message:new,
	// so a freshly-synced noise row cannot enter the normal client thread. Reaction
	// rows survive (renderRecommendation=merge) so tapbacks reach the client.
	for _, message := range store.FilterRenderableMessages(result.NewMessages) {
		if diagnostics != nil {
			diagnostics.recordEvent("message:new", message.ChatGUID)
		}
		_ = hub.Broadcast(ctx, realtime.Event{
			Type: "message:new",
			Data: message,
		})
	}
	// v0.11.x update-pass events.
	for _, update := range result.Updates {
		if diagnostics != nil {
			diagnostics.recordEvent("message:update", update.Message.ChatGUID)
		}
		_ = hub.Broadcast(ctx, realtime.Event{
			Type: "message:update",
			Data: map[string]any{
				"message": update.Message,
				"changed": update.Changed,
			},
		})
	}
	for _, unsent := range result.Unsent {
		if diagnostics != nil {
			diagnostics.recordEvent("message:unsend", &unsent.ChatGUID)
		}
		_ = hub.Broadcast(ctx, realtime.Event{
			Type: "message:unsend",
			Data: map[string]any{
				"guid":          unsent.GUID,
				"chatGuid":      unsent.ChatGUID,
				"dateRetracted": unsent.DateRetracted,
			},
		})
	}
}

func broadcastSendMatch(ctx context.Context, hub *realtime.Hub, tempGUID string, message store.MessageJSON, diagnostics *syncDiagnostics) {
	if hub == nil {
		return
	}
	if diagnostics != nil {
		diagnostics.recordEvent("send:match", message.ChatGUID)
	}
	_ = hub.Broadcast(ctx, realtime.Event{
		Type: "send:match",
		Data: map[string]any{
			"tempGuid": tempGUID,
			"message":  message,
			"late":     true,
		},
	})
}

func logSyncResult(result relaydb.SyncResult, force bool) {
	if !force && result.MessagesSynced == 0 {
		return
	}

	log.Printf("sync mode: %s", result.Mode)
	log.Printf("previous last_message_rowid: %d", result.PreviousLastMessageRowID)
	log.Printf("synced chats: %d", result.ChatsSynced)
	log.Printf("synced messages: %d", result.MessagesSynced)
	log.Printf("new last_message_rowid: %d", result.NewLastMessageRowID)
	if result.LastMessageGUID != "" {
		log.Printf("last synced message: guid=%s dateCreated=%d", result.LastMessageGUID, result.LastMessageDateCreated)
	}
}

func dispatchNotifications(ctx context.Context, dispatcher *notify.Dispatcher, relay *relaydb.DB, result relaydb.SyncResult) {
	if dispatcher == nil || len(result.NotificationEvents) == 0 || relay == nil {
		return
	}
	devices, err := relay.ListDevices(ctx)
	if err != nil {
		log.Printf("list devices for notification dispatch: %v", err)
		return
	}
	if err := dispatcher.DispatchNewMessages(ctx, devices, result.NotificationEvents); err != nil {
		log.Printf("dispatch notifications: %v", err)
	}
}

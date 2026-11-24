//go:build darwin

package app

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func startTestKqueueWatcher(
	t *testing.T,
	dbPath string,
	opts dbWatchOptions,
	diagnostics *syncDiagnostics,
) (triggers <-chan string, cancel context.CancelFunc, done <-chan struct{}) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	ready := make(chan struct{})
	opts.onReady = func() { close(ready) }
	ch := make(chan string, 32)
	doneCh := make(chan struct{})
	go func() {
		defer close(doneCh)
		if err := runDBKqueueWatchLoop(ctx, dbPath, opts, diagnostics, func(reason string) {
			select {
			case ch <- reason:
			default:
			}
		}); err != nil {
			t.Errorf("runDBKqueueWatchLoop returned error: %v", err)
		}
	}()
	select {
	case <-ready:
	case <-time.After(2 * time.Second):
		cancel()
		t.Fatal("kqueue watcher did not become ready")
	}
	t.Cleanup(func() {
		cancel()
		select {
		case <-doneCh:
		case <-time.After(2 * time.Second):
			t.Errorf("kqueue watcher did not exit during cleanup")
		}
	})
	return ch, cancel, doneCh
}

func countOpenFDs(t *testing.T) int {
	t.Helper()
	entries, err := os.ReadDir("/dev/fd")
	if err != nil {
		t.Fatalf("read /dev/fd: %v", err)
	}
	return len(entries)
}

func TestDBWatchKqueue_DelayedWALCreateAndLowLatency(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "chat.db")
	if err := os.WriteFile(dbPath, []byte("init"), 0o600); err != nil {
		t.Fatal(err)
	}

	diag := &syncDiagnostics{}
	triggers, _, _ := startTestKqueueWatcher(t, dbPath, dbWatchOptions{
		debounce:         defaultDBWatchDebounce,
		fallbackInterval: 30 * time.Second,
	}, diag)

	// chat.db-wal does not exist at startup; create it now and write to it.
	walPath := dbPath + "-wal"
	start := time.Now()
	if err := os.WriteFile(walPath, []byte("wal-frame-1"), 0o600); err != nil {
		t.Fatal(err)
	}

	select {
	case reason := <-triggers:
		elapsed := time.Since(start)
		t.Logf("delayed chat.db-wal create trigger=%q latency=%v", reason, elapsed)
		if reason != "chatdb_kqueue" {
			t.Fatalf("expected chatdb_kqueue trigger, got %q", reason)
		}
		if elapsed >= 50*time.Millisecond {
			t.Fatalf("expected wakeup latency < 50ms, got %v", elapsed)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for delayed chat.db-wal create trigger")
	}

	// Subsequent write to the newly attached WAL fd must also wake in < 50ms.
	f, err := os.OpenFile(walPath, os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	writeStart := time.Now()
	if _, err := f.Write([]byte("wal-frame-2")); err != nil {
		t.Fatal(err)
	}

	select {
	case reason := <-triggers:
		elapsed := time.Since(writeStart)
		t.Logf("chat.db-wal write trigger=%q latency=%v", reason, elapsed)
		if reason != "chatdb_kqueue" {
			t.Fatalf("expected chatdb_kqueue trigger, got %q", reason)
		}
		if elapsed >= 50*time.Millisecond {
			t.Fatalf("expected write wakeup latency < 50ms, got %v", elapsed)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for chat.db-wal write trigger")
	}
}

func TestDBWatchKqueue_DebounceBurstWrites(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "chat.db")
	walPath := dbPath + "-wal"
	if err := os.WriteFile(dbPath, []byte("init"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(walPath, []byte("wal-0"), 0o600); err != nil {
		t.Fatal(err)
	}

	triggers, _, _ := startTestKqueueWatcher(t, dbPath, dbWatchOptions{
		debounce:         45 * time.Millisecond,
		fallbackInterval: 30 * time.Second,
	}, nil)

	f, err := os.OpenFile(walPath, os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	// 10 consecutive writes within 10ms should coalesce into 1 trigger.
	burstStart := time.Now()
	for i := 0; i < 10; i++ {
		if _, err := f.Write([]byte("x")); err != nil {
			t.Fatal(err)
		}
		if time.Since(burstStart) < 8*time.Millisecond {
			time.Sleep(500 * time.Microsecond)
		}
	}

	select {
	case reason := <-triggers:
		if reason != "chatdb_kqueue" {
			t.Fatalf("expected chatdb_kqueue, got %q", reason)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for debounced trigger")
	}

	// Ensure no extra storm triggers arrive after the single coalesced wakeup.
	select {
	case extra := <-triggers:
		t.Fatalf("expected burst to coalesce into 1 trigger, got extra trigger %q", extra)
	case <-time.After(80 * time.Millisecond):
	}
}

func TestDBWatchKqueue_DeleteRecreateAndAtomicRenameRecovery(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "chat.db")
	walPath := dbPath + "-wal"
	if err := os.WriteFile(dbPath, []byte("db-v1"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(walPath, []byte("wal-v1"), 0o600); err != nil {
		t.Fatal(err)
	}
	oldTime := time.Now().Add(-time.Minute)
	_ = os.Chtimes(dbPath, oldTime, oldTime)
	_ = os.Chtimes(walPath, oldTime, oldTime)

	diag := &syncDiagnostics{}
	triggers, _, _ := startTestKqueueWatcher(t, dbPath, dbWatchOptions{
		debounce:         20 * time.Millisecond,
		fallbackInterval: 30 * time.Second,
	}, diag)

	initialSnap := diag.snapshot(0, 0)
	if initialSnap.LastChatDBMtime == nil || initialSnap.LastWALMtime == nil {
		t.Fatalf("expected initial mtimes recorded, got %+v", initialSnap)
	}

	drainTriggers := func() {
		for {
			select {
			case <-triggers:
			default:
				return
			}
		}
	}

	// 1. Delete chat.db-wal (simulating WAL checkpoint truncation/unlink) then recreate & write.
	if err := os.Remove(walPath); err != nil {
		t.Fatal(err)
	}
	select {
	case <-triggers:
	case <-time.After(2 * time.Second):
		t.Fatal("expected trigger after WAL delete")
	}
	drainTriggers()

	if err := os.WriteFile(walPath, []byte("wal-v2"), 0o600); err != nil {
		t.Fatal(err)
	}
	select {
	case reason := <-triggers:
		if reason != "chatdb_kqueue" {
			t.Fatalf("expected chatdb_kqueue after WAL recreate, got %q", reason)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("expected trigger after WAL recreate")
	}
	drainTriggers()

	// Write again to the recreated WAL to verify the new fd is actively watched.
	wf, err := os.OpenFile(walPath, os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := wf.Write([]byte("-more")); err != nil {
		_ = wf.Close()
		t.Fatal(err)
	}
	_ = wf.Close()
	select {
	case reason := <-triggers:
		if reason != "chatdb_kqueue" {
			t.Fatalf("expected chatdb_kqueue after write to recreated WAL, got %q", reason)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("expected trigger after write to recreated WAL")
	}
	drainTriggers()

	// 2. Atomic os.Rename(tmp, dbPath) replacement, then write to the new dbPath.
	tmpPath := filepath.Join(dir, "chat.db.tmp")
	if err := os.WriteFile(tmpPath, []byte("db-v2"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(tmpPath, dbPath); err != nil {
		t.Fatal(err)
	}
	select {
	case reason := <-triggers:
		if reason != "chatdb_kqueue" {
			t.Fatalf("expected chatdb_kqueue after atomic rename, got %q", reason)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("expected trigger after atomic rename")
	}
	drainTriggers()

	df, err := os.OpenFile(dbPath, os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := df.Write([]byte("-after-rename")); err != nil {
		_ = df.Close()
		t.Fatal(err)
	}
	_ = df.Close()
	select {
	case reason := <-triggers:
		if reason != "chatdb_kqueue" {
			t.Fatalf("expected chatdb_kqueue after write to renamed chat.db, got %q", reason)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("expected trigger after write to renamed chat.db")
	}

	afterSnap := diag.snapshot(0, 0)
	if afterSnap.LastChatDBMtime == nil || *afterSnap.LastChatDBMtime <= *initialSnap.LastChatDBMtime {
		t.Fatalf("expected chat.db mtime to advance: before=%v after=%v", initialSnap.LastChatDBMtime, afterSnap.LastChatDBMtime)
	}
	if afterSnap.LastWALMtime == nil || *afterSnap.LastWALMtime <= *initialSnap.LastWALMtime {
		t.Fatalf("expected wal mtime to advance: before=%v after=%v", initialSnap.LastWALMtime, afterSnap.LastWALMtime)
	}
}

func TestDBWatchKqueue_MissingChatDBAtStartup(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "chat.db")

	triggers, _, _ := startTestKqueueWatcher(t, dbPath, dbWatchOptions{
		debounce:         20 * time.Millisecond,
		fallbackInterval: 30 * time.Second,
	}, nil)

	if err := os.WriteFile(dbPath, []byte("created-later"), 0o600); err != nil {
		t.Fatal(err)
	}
	select {
	case reason := <-triggers:
		if reason != "chatdb_kqueue" {
			t.Fatalf("expected chatdb_kqueue, got %q", reason)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for trigger after creating missing chat.db")
	}

	// Follow-up write to the newly attached chat.db must also trigger.
	f, err := os.OpenFile(dbPath, os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err := f.Write([]byte("-update")); err != nil {
		t.Fatal(err)
	}
	select {
	case reason := <-triggers:
		if reason != "chatdb_kqueue" {
			t.Fatalf("expected chatdb_kqueue on follow-up write, got %q", reason)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for follow-up write trigger")
	}
}

func TestDBWatchKqueue_CancelExitsImmediatelyAndNoFDLeak(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "chat.db")
	for _, suffix := range []string{"", "-wal", "-shm"} {
		if err := os.WriteFile(dbPath+suffix, []byte("data"), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	// Warm up once before measuring baseline open FDs.
	baseline := countOpenFDs(t)

	for i := 0; i < 10; i++ {
		ctx, cancel := context.WithCancel(context.Background())
		ready := make(chan struct{})
		done := make(chan struct{})
		go func() {
			defer close(done)
			_ = runDBKqueueWatchLoop(ctx, dbPath, dbWatchOptions{
				debounce:         defaultDBWatchDebounce,
				fallbackInterval: 30 * time.Second,
				onReady:          func() { close(ready) },
			}, nil, func(string) {})
		}()

		select {
		case <-ready:
		case <-time.After(2 * time.Second):
			cancel()
			t.Fatalf("iteration %d: watcher did not become ready", i)
		}

		cancelStart := time.Now()
		cancel()
		select {
		case <-done:
			elapsed := time.Since(cancelStart)
			if elapsed >= 50*time.Millisecond {
				t.Fatalf("iteration %d: expected cancel exit < 50ms, got %v", i, elapsed)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("iteration %d: watcher did not exit after cancel", i)
		}
	}

	after := countOpenFDs(t)
	if after > baseline {
		t.Fatalf("FD leak detected after 10 watcher cycles: baseline=%d after=%d", baseline, after)
	}
}

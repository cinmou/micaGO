package app

import (
	"bytes"
	"context"
	"log"
	"micagoserver/internal/relaydb"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestPeriodicUnchangedScanIsQuiet(t *testing.T) {
	var output bytes.Buffer
	previous := log.Writer()
	log.SetOutput(&output)
	t.Cleanup(func() { log.SetOutput(previous) })
	result := relaydb.SyncResult{RowsScanned: 168, MessagesSynced: 168, MessagesUnchanged: 168}
	logSyncResult(result, false)
	if output.Len() != 0 {
		t.Fatalf("unchanged scan logged: %s", output.String())
	}
	result.MessagesWritten = 1
	result.MessagesUnchanged = 167
	logSyncResult(result, false)
	if !strings.Contains(output.String(), "changed: 1, unchanged: 167") {
		t.Fatal("changed scan missing counters")
	}
	output.Reset()
	logSyncResult(relaydb.SyncResult{}, true)
	if output.Len() == 0 {
		t.Fatal("forced startup diagnostics were suppressed")
	}
}

func TestPeriodicLoopTriggersAndStops(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	reasons := make(chan string, 1)
	go func() {
		defer close(done)
		runSyncLoop(ctx, 5*time.Millisecond, func(reason string) {
			select {
			case reasons <- reason:
			default:
			}
			cancel()
		})
	}()
	select {
	case reason := <-reasons:
		if reason != "periodic" {
			t.Fatalf("unexpected trigger: %s", reason)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("periodic trigger did not fire")
	}
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("periodic loop did not stop")
	}
}

func TestMtimeLoopTriggersForDatabaseAndSidecars(t *testing.T) {
	for _, suffix := range []string{"", "-wal", "-shm"} {
		t.Run("chat.db"+suffix, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "chat.db")
			changedPath := path + suffix
			if err := os.WriteFile(changedPath, nil, 0o600); err != nil {
				t.Fatal(err)
			}
			initial := time.Now().Add(-time.Minute)
			if err := os.Chtimes(changedPath, initial, initial); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			diagnostics := &syncDiagnostics{}
			done := make(chan struct{})
			reasons := make(chan string, 1)
			go func() {
				defer close(done)
				runDBMtimeSyncLoop(ctx, path, 5*time.Millisecond, diagnostics, func(reason string) {
					reasons <- reason
					cancel()
				})
			}()
			waitFor(t, func() bool {
				d := diagnostics.snapshot(0, 0)
				return d.LastChatDBMtime != nil || d.LastWALMtime != nil || d.LastSHMMtime != nil
			})
			select {
			case reason := <-reasons:
				t.Fatalf("unchanged file triggered sync: %s", reason)
			case <-time.After(20 * time.Millisecond):
			}
			now := time.Now()
			if err := os.Chtimes(changedPath, now, now); err != nil {
				t.Fatal(err)
			}
			select {
			case reason := <-reasons:
				if reason != "chatdb_mtime" {
					t.Fatalf("unexpected trigger: %s", reason)
				}
			case <-time.After(2 * time.Second):
				t.Fatal("mtime trigger did not fire")
			}
			select {
			case <-done:
			case <-time.After(2 * time.Second):
				t.Fatal("mtime loop did not stop")
			}
		})
	}
}

package app

import (
	"bytes"
	"log"
	"micagoserver/internal/relaydb"
	"strings"
	"testing"
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

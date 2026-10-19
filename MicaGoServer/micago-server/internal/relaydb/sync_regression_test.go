package relaydb

import (
	"context"
	"micagoserver/internal/store"
	"testing"
	"time"
)

func TestLookbackDoesNotAdvancePastIncrementalPage(t *testing.T) {
	db := openTestDB(t)
	db.SetSyncState("last_message_rowid", "100")
	src := &lookbackSource{chats: []store.SyncChatRow{{GUID: "c"}}, sinceRows: []store.SyncMessageRow{{GUID: "m101", ChatGUID: "c", SourceRowID: 101, Text: s("a")}, {GUID: "m102", ChatGUID: "c", SourceRowID: 102, Text: s("b")}}, dateRows: []store.SyncMessageRow{{GUID: "m106", ChatGUID: "c", SourceRowID: 106, Text: s("f")}, {GUID: "m105", ChatGUID: "c", SourceRowID: 105, Text: s("e")}}}
	r, e := SyncOnce(context.Background(), src, db, 2, time.Hour)
	if e != nil {
		t.Fatal(e)
	}
	if r.NewLastMessageRowID != 102 {
		t.Fatalf("cursor jumped to %d; rows 103 and 104 were never scanned", r.NewLastMessageRowID)
	}
}
func TestFirstStateSeedRefreshesRelay(t *testing.T) {
	db := openTestDB(t)
	insertRelayMessage(t, db, "m1", "c", "old")
	src := &fakeUpdateSource{rows: []store.MessageUpdateRow{{GUID: "m1", ChatGUID: "c", Text: s("edited"), IsRead: true, DateEdited: i64(time.Now().UnixMilli())}}}
	for i := 0; i < 2; i++ {
		if _, e := UpdatePass(context.Background(), src, db, fullCaps, time.Hour); e != nil {
			t.Fatal(e)
		}
	}
	var text string
	var read int
	db.sqlDB.QueryRow("SELECT text,is_read FROM messages WHERE guid='m1'").Scan(&text, &read)
	if text != "edited" || read != 1 {
		t.Fatalf("after two passes relay remains text=%q is_read=%d", text, read)
	}
}

func TestUpdatePassRepairsPreviouslySeededStaleRowOnce(t *testing.T) {
	db := openTestDB(t)
	insertRelayMessage(t, db, "m1", "c", "old")
	row := store.MessageUpdateRow{GUID: "m1", ChatGUID: "c", Text: s("correct"), IsRead: true}
	tx, err := db.sqlDB.Begin()
	if err != nil {
		t.Fatal(err)
	}
	if err := upsertMessageStateTx(tx, row.GUID, row.State(), row.State().Fingerprint(fullCaps), time.Now().UnixMilli()); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	src := &fakeUpdateSource{rows: []store.MessageUpdateRow{row}}
	first, err := UpdatePass(context.Background(), src, db, fullCaps, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if len(first.Updates) != 1 || first.Updates[0].Message.Text == nil || *first.Updates[0].Message.Text != "correct" {
		t.Fatalf("stale row was not repaired: %+v", first)
	}
	second, err := UpdatePass(context.Background(), src, db, fullCaps, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if len(second.Updates) != 0 {
		t.Fatal("unchanged row emitted again")
	}
}

type pagedStateSource struct {
	fakeUpdateSource
	calls []int64
	fail  bool
}

func (s *pagedStateSource) ListMessageUpdatesPage(_ context.Context, _ int64, after int64, limit int, _ store.SchemaCapabilities) ([]store.MessageUpdateRow, error) {
	s.calls = append(s.calls, after)
	if s.fail {
		return nil, context.Canceled
	}
	var out []store.MessageUpdateRow
	for _, r := range s.rows {
		if r.SourceRowID > after {
			out = append(out, r)
			if len(out) == limit {
				break
			}
		}
	}
	return out, nil
}
func TestUpdatePagesResumeAfterRestartAndWrap(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	insertRelayMessage(t, db, "tail", "c", "old")
	src := &pagedStateSource{}
	for i := 1; i <= updateWindowLimit; i++ {
		src.rows = append(src.rows, store.MessageUpdateRow{SourceRowID: int64(i), GUID: "untracked"})
	}
	src.rows = append(src.rows, store.MessageUpdateRow{SourceRowID: updateWindowLimit + 1, GUID: "tail", ChatGUID: "c", Text: s("updated")})
	if _, e := UpdatePass(ctx, src, db, fullCaps, time.Hour); e != nil {
		t.Fatal(e)
	}
	saved, _, _ := db.GetSyncState("update_scan_rowid")
	if saved != "5000" {
		t.Fatalf("cursor=%s", saved)
	}
	// Reopen the same database: continuation must be durable, not worker memory.
	path := db.path
	db.Close()
	var e error
	db, e = Open(path)
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	if _, e := UpdatePass(ctx, src, db, fullCaps, time.Hour); e != nil {
		t.Fatal(e)
	}
	var text string
	db.sqlDB.QueryRow("SELECT text FROM messages WHERE guid='tail'").Scan(&text)
	if text != "updated" {
		t.Fatalf("last page not refreshed: %q", text)
	}
	saved, _, _ = db.GetSyncState("update_scan_rowid")
	if saved != "0" {
		t.Fatalf("must wrap, cursor=%s", saved)
	}
	if len(src.calls) != 2 || src.calls[1] != 5000 {
		t.Fatalf("calls=%v", src.calls)
	}
	db.SetSyncState("update_scan_rowid", "42")
	src.fail = true
	if _, e := UpdatePass(ctx, src, db, fullCaps, time.Hour); e == nil {
		t.Fatal("expected source failure")
	}
	saved, _, _ = db.GetSyncState("update_scan_rowid")
	if saved != "42" {
		t.Fatal("failed scan changed cursor")
	}
}

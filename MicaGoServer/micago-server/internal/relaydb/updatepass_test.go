package relaydb

import (
	"context"
	"testing"
	"time"

	"micagoserver/internal/store"
)

var fullCaps = store.SchemaCapabilities{
	EditedMessages:  true,
	UnsentMessages:  true,
	ReadStatus:      true,
	DeliveredStatus: true,
	SendError:       true,
}

type fakeUpdateSource struct {
	rows []store.MessageUpdateRow
}

func (f *fakeUpdateSource) ListMessageUpdatesPage(_ context.Context, _ int64, _ int64, _ int, _ store.SchemaCapabilities) ([]store.MessageUpdateRow, error) {
	return f.rows, nil
}

func i64(v int64) *int64 { return &v }
func s(v string) *string { return &v }

// insertRelayMessage seeds a message into relay.messages so the update pass
// treats it as a tracked message.
func insertRelayMessage(t *testing.T, db *DB, guid, chatGUID, text string) {
	t.Helper()
	now := time.Now().UnixMilli()
	_, err := db.sqlDB.Exec(`
INSERT INTO messages (guid, chat_guid, source_rowid, text, date_created, is_from_me, is_read, is_delivered, cache_has_attachments, created_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		guid, chatGUID, 1, text, now, 1, 0, 0, 0, now)
	if err != nil {
		t.Fatalf("insert relay message: %v", err)
	}
}

func TestUpdatePassFirstScanSeedsWithoutBroadcast(t *testing.T) {
	db := openTestDB(t)
	insertRelayMessage(t, db, "m1", "chat-1", "hello")

	source := &fakeUpdateSource{rows: []store.MessageUpdateRow{
		{GUID: "m1", ChatGUID: "chat-1", Text: s("hello"), IsFromMe: true, IsRead: false},
	}}

	res, err := UpdatePass(context.Background(), source, db, fullCaps, 168*time.Hour)
	if err != nil {
		t.Fatalf("update pass: %v", err)
	}
	if len(res.Updates) != 0 || len(res.Unsent) != 0 {
		t.Fatalf("first scan must not broadcast, got updates=%d unsent=%d", len(res.Updates), len(res.Unsent))
	}
	if res.Seeded != 1 {
		t.Fatalf("expected 1 seeded, got %d", res.Seeded)
	}
	// State row should now exist.
	var cnt int
	if err := db.sqlDB.QueryRow(`SELECT COUNT(*) FROM message_state WHERE guid='m1'`).Scan(&cnt); err != nil || cnt != 1 {
		t.Fatalf("expected seeded message_state, cnt=%d err=%v", cnt, err)
	}
}

func TestUpdatePassReadChangeEmitsUpdate(t *testing.T) {
	db := openTestDB(t)
	insertRelayMessage(t, db, "m1", "chat-1", "hello")
	source := &fakeUpdateSource{rows: []store.MessageUpdateRow{
		{GUID: "m1", ChatGUID: "chat-1", Text: s("hello"), IsRead: false},
	}}
	if _, err := UpdatePass(context.Background(), source, db, fullCaps, time.Hour); err != nil {
		t.Fatalf("seed: %v", err)
	}

	// Now the message is read.
	source.rows = []store.MessageUpdateRow{
		{GUID: "m1", ChatGUID: "chat-1", Text: s("hello"), IsRead: true, DateRead: i64(1717372800000)},
	}
	res, err := UpdatePass(context.Background(), source, db, fullCaps, time.Hour)
	if err != nil {
		t.Fatalf("update pass: %v", err)
	}
	if len(res.Updates) != 1 {
		t.Fatalf("expected 1 update, got %d", len(res.Updates))
	}
	if !containsStr(res.Updates[0].Changed, "isRead") || !containsStr(res.Updates[0].Changed, "dateRead") {
		t.Fatalf("expected isRead+dateRead changed, got %v", res.Updates[0].Changed)
	}
	if !res.Updates[0].Message.IsRead {
		t.Fatalf("emitted message should reflect isRead=true")
	}
}

func TestUpdatePassEditedEmitsUpdate(t *testing.T) {
	db := openTestDB(t)
	insertRelayMessage(t, db, "m1", "chat-1", "original")
	source := &fakeUpdateSource{rows: []store.MessageUpdateRow{
		{GUID: "m1", ChatGUID: "chat-1", Text: s("original")},
	}}
	if _, err := UpdatePass(context.Background(), source, db, fullCaps, time.Hour); err != nil {
		t.Fatalf("seed: %v", err)
	}

	source.rows = []store.MessageUpdateRow{
		{GUID: "m1", ChatGUID: "chat-1", Text: s("edited text"), DateEdited: i64(1717372800000)},
	}
	res, err := UpdatePass(context.Background(), source, db, fullCaps, time.Hour)
	if err != nil {
		t.Fatalf("update pass: %v", err)
	}
	if len(res.Updates) != 1 {
		t.Fatalf("expected 1 update, got %d", len(res.Updates))
	}
	if !containsStr(res.Updates[0].Changed, "isEdited") || !containsStr(res.Updates[0].Changed, "text") {
		t.Fatalf("expected isEdited+text changed, got %v", res.Updates[0].Changed)
	}
	if got := derefStr(res.Updates[0].Message.Text); got != "edited text" {
		t.Fatalf("emitted message text should reflect edit, got %q", got)
	}
}

func TestUpdatePassRetractedEmitsUnsend(t *testing.T) {
	db := openTestDB(t)
	insertRelayMessage(t, db, "m1", "chat-1", "to be unsent")
	source := &fakeUpdateSource{rows: []store.MessageUpdateRow{
		{GUID: "m1", ChatGUID: "chat-1", Text: s("to be unsent")},
	}}
	if _, err := UpdatePass(context.Background(), source, db, fullCaps, time.Hour); err != nil {
		t.Fatalf("seed: %v", err)
	}

	source.rows = []store.MessageUpdateRow{
		{GUID: "m1", ChatGUID: "chat-1", Text: s(""), DateRetracted: i64(1717372800000)},
	}
	res, err := UpdatePass(context.Background(), source, db, fullCaps, time.Hour)
	if err != nil {
		t.Fatalf("update pass: %v", err)
	}
	if len(res.Unsent) != 1 {
		t.Fatalf("expected 1 unsend, got %d (updates=%d)", len(res.Unsent), len(res.Updates))
	}
	if res.Unsent[0].GUID != "m1" || res.Unsent[0].DateRetracted == nil {
		t.Fatalf("unexpected unsend event: %+v", res.Unsent[0])
	}
}

func TestUpdatePassUnchangedDoesNotRebroadcast(t *testing.T) {
	db := openTestDB(t)
	insertRelayMessage(t, db, "m1", "chat-1", "hello")
	row := store.MessageUpdateRow{GUID: "m1", ChatGUID: "chat-1", Text: s("hello"), IsRead: true, DateRead: i64(123)}
	source := &fakeUpdateSource{rows: []store.MessageUpdateRow{row}}
	if _, err := UpdatePass(context.Background(), source, db, fullCaps, time.Hour); err != nil {
		t.Fatalf("seed: %v", err)
	}

	// Same state again.
	res, err := UpdatePass(context.Background(), source, db, fullCaps, time.Hour)
	if err != nil {
		t.Fatalf("update pass: %v", err)
	}
	if len(res.Updates) != 0 || len(res.Unsent) != 0 {
		t.Fatalf("unchanged row must not rebroadcast, got updates=%d unsent=%d", len(res.Updates), len(res.Unsent))
	}
}

func TestUpdatePassDisabledByZeroLookback(t *testing.T) {
	db := openTestDB(t)
	insertRelayMessage(t, db, "m1", "chat-1", "hello")
	source := &fakeUpdateSource{rows: []store.MessageUpdateRow{{GUID: "m1", ChatGUID: "chat-1", IsRead: true}}}
	res, err := UpdatePass(context.Background(), source, db, fullCaps, 0)
	if err != nil {
		t.Fatalf("update pass: %v", err)
	}
	if res.Scanned != 0 || len(res.Updates) != 0 {
		t.Fatalf("zero lookback should disable the pass, got %+v", res)
	}
}

func TestUpdatePassMissingCapabilitiesSkipsUnsupportedChanges(t *testing.T) {
	db := openTestDB(t)
	insertRelayMessage(t, db, "m1", "chat-1", "hello")
	// Only read/delivered enabled; edited/unsent/error disabled.
	caps := store.SchemaCapabilities{ReadStatus: true, DeliveredStatus: true}
	source := &fakeUpdateSource{rows: []store.MessageUpdateRow{
		{GUID: "m1", ChatGUID: "chat-1", Text: s("hello")},
	}}
	if _, err := UpdatePass(context.Background(), source, db, caps, time.Hour); err != nil {
		t.Fatalf("seed: %v", err)
	}

	// A row carrying edited+retracted info, but those caps are off: no events.
	source.rows = []store.MessageUpdateRow{
		{GUID: "m1", ChatGUID: "chat-1", Text: s("edited?"), DateEdited: i64(999), DateRetracted: i64(999)},
	}
	res, err := UpdatePass(context.Background(), source, db, caps, time.Hour)
	if err != nil {
		t.Fatalf("update pass: %v", err)
	}
	if len(res.Updates) != 0 || len(res.Unsent) != 0 {
		t.Fatalf("disabled caps must not emit edited/unsend, got updates=%d unsent=%d", len(res.Updates), len(res.Unsent))
	}
}

func containsStr(items []string, want string) bool {
	for _, it := range items {
		if it == want {
			return true
		}
	}
	return false
}

func derefStr(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

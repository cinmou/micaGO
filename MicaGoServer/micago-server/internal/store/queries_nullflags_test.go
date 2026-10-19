package store

import (
	"context"
	"testing"
)

// Real chat.db rows frequently store the boolean flag columns (is_from_me,
// is_read, is_delivered, cache_has_attachments) as NULL. Scanning NULL into a
// plain int64 fails and previously aborted the entire startup sync — taking the
// whole HTTP API (Sync Control, Paired Devices) down with it. Both the
// initial-sync read and the update read must treat NULL as 0/false.
func TestSyncReadsTolerateNullFlagColumns(t *testing.T) {
	ddl := append([]string{
		`CREATE TABLE message (
			ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB,
			subject TEXT, service TEXT, date INTEGER, date_read INTEGER, date_delivered INTEGER,
			is_from_me INTEGER, is_read INTEGER, is_delivered INTEGER, cache_has_attachments INTEGER,
			handle_id INTEGER
		)`,
		// All four flag columns left NULL on purpose.
		`INSERT INTO message (ROWID, guid, text, date, handle_id)
		 VALUES (1, 'm1', 'hi', 700000000000000000, 1)`,
	}, chatDBCommonDDL()...)
	db := newSchemaDB(t, ddl...)

	caps, err := ProbeCapabilities(context.Background(), db)
	if err != nil {
		t.Fatalf("probe: %v", err)
	}
	q := NewQueries(db)

	// Initial-sync path (scanSyncRowSemantic) — must not error on NULL flags.
	recent, err := q.ListSyncRecentMessages(context.Background(), 100)
	if err != nil {
		t.Fatalf("ListSyncRecentMessages with NULL flags: %v", err)
	}
	if len(recent) != 1 {
		t.Fatalf("expected 1 synced message, got %d", len(recent))
	}
	if recent[0].IsRead || recent[0].IsFromMe || recent[0].IsDelivered ||
		recent[0].CacheHasAttachments {
		t.Fatalf("NULL flags should default to false, got %+v", recent[0])
	}

	// Update path (ListMessageUpdatesPage) — same NULL tolerance.
	updates, err := q.ListMessageUpdatesPage(context.Background(), 0, 0, 100, caps)
	if err != nil {
		t.Fatalf("ListMessageUpdatesPage with NULL flags: %v", err)
	}
	if len(updates) != 1 {
		t.Fatalf("expected 1 update row, got %d", len(updates))
	}
}

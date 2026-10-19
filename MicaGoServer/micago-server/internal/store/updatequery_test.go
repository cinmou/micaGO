package store

import (
	"context"
	"fmt"
	"testing"
)

// chatDBCommonDDL returns the join/chat/handle tables shared by both schemas.
func chatDBCommonDDL() []string {
	return []string{
		`CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, service_name TEXT)`,
		`CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT)`,
		`CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER)`,
		`CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, guid TEXT, mime_type TEXT, transfer_name TEXT, total_bytes INTEGER)`,
		`INSERT INTO chat (ROWID, guid, service_name) VALUES (1, 'chat-1', 'iMessage')`,
		`INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 1)`,
	}
}

func TestListMessageUpdatesPageModernSchema(t *testing.T) {
	ddl := append([]string{
		`CREATE TABLE message (
			ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB,
			subject TEXT, service TEXT, date INTEGER, date_read INTEGER, date_delivered INTEGER,
			is_from_me INTEGER, is_read INTEGER, is_delivered INTEGER, cache_has_attachments INTEGER,
			handle_id INTEGER, date_edited INTEGER, date_retracted INTEGER, error INTEGER
		)`,
		// date ~ 7e17 ns since Apple epoch (a modern timestamp).
		`INSERT INTO message (ROWID, guid, text, date, date_read, is_from_me, is_read, is_delivered, cache_has_attachments, date_edited, error)
		 VALUES (1, 'm1', 'edited body', 700000000000000000, 0, 1, 0, 1, 0, 700000000000000001, 0)`,
	}, chatDBCommonDDL()...)
	db := newSchemaDB(t, ddl...)

	caps, err := ProbeCapabilities(context.Background(), db)
	if err != nil {
		t.Fatalf("probe: %v", err)
	}
	if !caps.EditedMessages || !caps.UnsentMessages || !caps.SendError {
		t.Fatalf("expected edit/unsent/error caps true, got %+v", caps)
	}

	q := NewQueries(db)
	updates, err := q.ListMessageUpdatesPage(context.Background(), 0, 0, 100, caps)
	if err != nil {
		t.Fatalf("ListMessageUpdatesPage: %v", err)
	}
	if len(updates) != 1 {
		t.Fatalf("expected 1 update row, got %d", len(updates))
	}
	if updates[0].GUID != "m1" || updates[0].ChatGUID != "chat-1" {
		t.Fatalf("unexpected row: %+v", updates[0])
	}
	if updates[0].DateEdited == nil {
		t.Fatalf("expected DateEdited populated on modern schema")
	}
}

func TestListMessageUpdatesPageOldSchemaDoesNotCrash(t *testing.T) {
	// No date_edited / date_retracted / error columns at all.
	ddl := append([]string{
		`CREATE TABLE message (
			ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB,
			subject TEXT, service TEXT, date INTEGER, date_read INTEGER, date_delivered INTEGER,
			is_from_me INTEGER, is_read INTEGER, is_delivered INTEGER, cache_has_attachments INTEGER,
			handle_id INTEGER
		)`,
		`INSERT INTO message (ROWID, guid, text, date, is_from_me, is_read, is_delivered, cache_has_attachments)
		 VALUES (1, 'm1', 'hi', 700000000000000000, 1, 1, 1, 0)`,
	}, chatDBCommonDDL()...)
	db := newSchemaDB(t, ddl...)

	caps, err := ProbeCapabilities(context.Background(), db)
	if err != nil {
		t.Fatalf("probe: %v", err)
	}
	if caps.EditedMessages || caps.UnsentMessages || caps.SendError {
		t.Fatalf("expected edit/unsent/error caps false on old schema, got %+v", caps)
	}

	q := NewQueries(db)
	// Must not reference missing columns -> must not error.
	updates, err := q.ListMessageUpdatesPage(context.Background(), 0, 0, 100, caps)
	if err != nil {
		t.Fatalf("old-schema query should not crash, got: %v", err)
	}
	if len(updates) != 1 {
		t.Fatalf("expected 1 row, got %d", len(updates))
	}
	if updates[0].DateEdited != nil || updates[0].DateRetracted != nil {
		t.Fatalf("expected no edited/retracted data on old schema")
	}
	if !updates[0].IsRead {
		t.Fatalf("expected IsRead true from row")
	}
}

// guard: ensure the query handles an empty result set cleanly.
func TestListMessageUpdatesPageNoRows(t *testing.T) {
	ddl := append([]string{
		`CREATE TABLE message (
			ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB,
			subject TEXT, service TEXT, date INTEGER, date_read INTEGER, date_delivered INTEGER,
			is_from_me INTEGER, is_read INTEGER, is_delivered INTEGER, cache_has_attachments INTEGER, handle_id INTEGER
		)`,
	}, chatDBCommonDDL()...)
	db := newSchemaDB(t, ddl...)
	caps, _ := ProbeCapabilities(context.Background(), db)
	q := NewQueries(db)
	updates, err := q.ListMessageUpdatesPage(context.Background(), 0, 0, 100, caps)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if len(updates) != 0 {
		t.Fatalf("expected 0 rows, got %d", len(updates))
	}
}

func TestMessageUpdatePagesUseRowIDDespiteReorderedDates(t *testing.T) {
	ddl := append([]string{`CREATE TABLE message (
 ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB,
 subject TEXT, service TEXT, date INTEGER, date_read INTEGER, date_delivered INTEGER,
 is_from_me INTEGER, is_read INTEGER, is_delivered INTEGER, cache_has_attachments INTEGER,handle_id INTEGER
 )`}, chatDBCommonDDL()...)
	db := newSchemaDB(t, ddl...)
	for i := 1; i <= 3; i++ {
		if _, err := db.Exec(`INSERT INTO message(ROWID,guid,text,date) VALUES(?,?,?,?)`, i, fmt.Sprintf("m%d", i), "text", int64(700000000000000000-i)); err != nil {
			t.Fatal(err)
		}
		if i > 1 {
			if _, err := db.Exec(`INSERT INTO chat_message_join VALUES(1,?)`, i); err != nil {
				t.Fatal(err)
			}
		}
	}
	q := NewQueries(db)
	first, err := q.ListMessageUpdatesPage(context.Background(), 0, 0, 2, SchemaCapabilities{})
	if err != nil {
		t.Fatal(err)
	}
	if len(first) != 2 || first[0].SourceRowID != 1 || first[1].SourceRowID != 2 {
		t.Fatalf("first page=%+v", first)
	}
	second, err := q.ListMessageUpdatesPage(context.Background(), 0, first[1].SourceRowID, 2, SchemaCapabilities{})
	if err != nil {
		t.Fatal(err)
	}
	if len(second) != 1 || second[0].SourceRowID != 3 {
		t.Fatalf("second page=%+v", second)
	}
}

func TestListSyncRecentMessagesByDateScansEmailHandleWithAccountColumn(t *testing.T) {
	db := newSchemaDB(t,
		`CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, service_name TEXT, display_name TEXT, is_archived INTEGER)`,
		`CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER)`,
		`CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT)`,
		`CREATE TABLE message (
			ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB,
			subject TEXT, service TEXT, account TEXT, date INTEGER, date_read INTEGER,
			date_delivered INTEGER, is_from_me INTEGER, is_read INTEGER, is_delivered INTEGER,
			cache_has_attachments INTEGER, handle_id INTEGER
		)`,
		`INSERT INTO chat (ROWID, guid, service_name) VALUES (1, 'chat-1', 'iMessage')`,
		`INSERT INTO handle (ROWID, id, service) VALUES (1, 'wppe_a@icloud.com', 'iMessage')`,
		`INSERT INTO message (
			ROWID, guid, text, service, account, date, is_from_me, is_read,
			is_delivered, cache_has_attachments, handle_id
		) VALUES (1, 'm1', 'hello', 'iMessage', 'user@example.com', 1000, 0, 1, 1, 0, 1)`,
		`INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 1)`,
	)

	q := NewQueries(db)
	q.SetMessageColumns(map[string]bool{"account": true})
	rows, err := q.ListSyncRecentMessagesByDate(context.Background(), 0, 10)
	if err != nil {
		t.Fatalf("ListSyncRecentMessagesByDate: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}
	if rows[0].HandleID == nil || *rows[0].HandleID != "wppe_a@icloud.com" {
		t.Fatalf("handle = %v", rows[0].HandleID)
	}
	if rows[0].Account == nil || *rows[0].Account != "user@example.com" {
		t.Fatalf("account = %v", rows[0].Account)
	}
}

func TestListSyncRecentMessagesByDateScansEmailHandleWithoutAccountColumn(t *testing.T) {
	db := newSchemaDB(t,
		`CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, service_name TEXT, display_name TEXT, is_archived INTEGER)`,
		`CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER)`,
		`CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT)`,
		`CREATE TABLE message (
			ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB,
			subject TEXT, service TEXT, date INTEGER, date_read INTEGER,
			date_delivered INTEGER, is_from_me INTEGER, is_read INTEGER, is_delivered INTEGER,
			cache_has_attachments INTEGER, handle_id INTEGER
		)`,
		`INSERT INTO chat (ROWID, guid, service_name) VALUES (1, 'chat-1', 'iMessage')`,
		`INSERT INTO handle (ROWID, id, service) VALUES (1, 'wppe_a@icloud.com', 'iMessage')`,
		`INSERT INTO message (
			ROWID, guid, text, service, date, is_from_me, is_read,
			is_delivered, cache_has_attachments, handle_id
		) VALUES (1, 'm1', 'hello', 'iMessage', 1000, 0, 1, 1, 0, 1)`,
		`INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 1)`,
	)

	q := NewQueries(db)
	rows, err := q.ListSyncRecentMessagesByDate(context.Background(), 0, 10)
	if err != nil {
		t.Fatalf("ListSyncRecentMessagesByDate: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}
	if rows[0].HandleID == nil || *rows[0].HandleID != "wppe_a@icloud.com" {
		t.Fatalf("handle = %v", rows[0].HandleID)
	}
	if rows[0].Account != nil {
		t.Fatalf("account = %v", rows[0].Account)
	}
}

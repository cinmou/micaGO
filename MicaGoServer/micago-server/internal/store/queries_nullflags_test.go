package store

import (
	"context"
	"fmt"
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

func TestSyncReadsTolerateNullChatDateAndAttachmentColumns(t *testing.T) {
	db := newSchemaDB(t,
		`CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, service_name TEXT, display_name TEXT, is_archived INTEGER, style INTEGER)`,
		`CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT)`,
		`CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER)`,
		`CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER)`,
		`CREATE TABLE message (
			ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB,
			subject TEXT, service TEXT, account TEXT, date INTEGER, date_read INTEGER, date_delivered INTEGER,
			is_from_me INTEGER, is_read INTEGER, is_delivered INTEGER, cache_has_attachments INTEGER,
			handle_id INTEGER, error INTEGER
		)`,
		`CREATE TABLE attachment (
			ROWID INTEGER PRIMARY KEY, guid TEXT, filename TEXT, mime_type TEXT, transfer_name TEXT,
			total_bytes INTEGER, is_outgoing INTEGER, hide_attachment INTEGER, created_date INTEGER,
			uti TEXT, is_sticker INTEGER
		)`,
		`CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER)`,
		`INSERT INTO chat (ROWID, guid, chat_identifier, service_name, display_name, is_archived, style) VALUES (1, 'iMessage;-;+15550001', '+15550001', 'iMessage', '', NULL, 45)`,
		`INSERT INTO handle (ROWID, id, service) VALUES (1, '+15550001', 'iMessage')`,
		`INSERT INTO message (ROWID, guid, text, service, date, is_from_me, cache_has_attachments, handle_id, error) VALUES (1, 'm-null-date', 'hello', 'iMessage', NULL, 1, 1, 1, 22)`,
		`INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 1)`,
		`INSERT INTO attachment (ROWID, guid, filename, mime_type, transfer_name, total_bytes, is_outgoing, hide_attachment, created_date, uti, is_sticker) VALUES (1, 'att-null', 'a.jpg', 'image/jpeg', 'a.jpg', NULL, NULL, NULL, NULL, 'public.jpeg', NULL)`,
		`INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (1, 1)`,
	)

	ctx := context.Background()
	caps, err := ProbeCapabilities(ctx, db)
	if err != nil {
		t.Fatalf("probe: %v", err)
	}
	q := NewQueries(db)

	chats, err := q.ListSyncChats(ctx)
	if err != nil {
		t.Fatalf("ListSyncChats with NULL is_archived: %v", err)
	}
	if len(chats) != 1 || chats[0].IsArchived {
		t.Fatalf("unexpected chats: %+v", chats)
	}

	recent, err := q.ListSyncRecentMessages(ctx, 100)
	if err != nil {
		t.Fatalf("ListSyncRecentMessages with NULL date: %v", err)
	}
	if len(recent) != 1 || recent[0].DateCreated != nil {
		t.Fatalf("expected 1 message with nil DateCreated, got %+v", recent)
	}

	updates, err := q.ListMessageUpdatesPage(ctx, 0, 0, 100, caps)
	if err != nil {
		t.Fatalf("ListMessageUpdatesPage with NULL date: %v", err)
	}
	if len(updates) != 0 {
		// m.date IS NULL does not satisfy m.date >= after; ensure scan path works when matched via negative after or direct check.
		t.Logf("updates matched: %d", len(updates))
	}

	_, found, err := q.FindOutgoingMessageError(ctx, "iMessage;-;+15550001", "hello", 0)
	if err != nil {
		t.Fatalf("FindOutgoingMessageError with NULL date: %v", err)
	}
	if found {
		t.Fatalf("expected NULL date row not to match outgoing error")
	}

	atts, err := q.ListSyncAttachmentsForMessages(ctx, []string{"m-null-date"})
	if err != nil {
		t.Fatalf("ListSyncAttachmentsForMessages with NULL columns: %v", err)
	}
	if len(atts) != 1 || atts[0].TotalBytes != 0 || atts[0].IsOutgoing || atts[0].HideAttachment || atts[0].IsSticker {
		t.Fatalf("unexpected attachment row: %+v", atts)
	}
}

func TestListSyncAttachmentsForMessagesChunksOverSQLiteLimit(t *testing.T) {
	db := newSchemaDB(t,
		`CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT)`,
		`CREATE TABLE attachment (
			ROWID INTEGER PRIMARY KEY, guid TEXT, filename TEXT, mime_type TEXT, transfer_name TEXT,
			total_bytes INTEGER, is_outgoing INTEGER, hide_attachment INTEGER, created_date INTEGER,
			uti TEXT, is_sticker INTEGER
		)`,
		`CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER)`,
		`INSERT INTO message (ROWID, guid) VALUES (1, 'msg-0001'), (2, 'msg-0750'), (3, 'msg-1250')`,
		`INSERT INTO attachment (ROWID, guid, filename, mime_type, transfer_name, total_bytes, is_outgoing, hide_attachment, created_date, uti, is_sticker) VALUES
			(1, 'att-1', '1.jpg', 'image/jpeg', '1.jpg', 10, 0, 0, 100, 'public.jpeg', 0),
			(2, 'att-2', '2.jpg', 'image/jpeg', '2.jpg', 20, 0, 0, 200, 'public.jpeg', 0),
			(3, 'att-3', '3.jpg', 'image/jpeg', '3.jpg', 30, 0, 0, 300, 'public.jpeg', 0)`,
		`INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (1, 1), (2, 2), (3, 3)`,
	)

	guids := make([]string, 0, 1260)
	for i := 1; i <= 1250; i++ {
		guids = append(guids, fmt.Sprintf("msg-%04d", i))
	}
	guids = append(guids, "msg-0001", "msg-0750") // duplicates

	q := NewQueries(db)
	atts, err := q.ListSyncAttachmentsForMessages(context.Background(), guids)
	if err != nil {
		t.Fatalf("ListSyncAttachmentsForMessages failed on %d GUIDs: %v", len(guids), err)
	}
	if len(atts) != 3 {
		t.Fatalf("expected 3 attachments across chunks, got %d", len(atts))
	}
}

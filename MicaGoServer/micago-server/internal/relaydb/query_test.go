package relaydb

import (
	"context"
	"fmt"
	"testing"

	"micagoserver/internal/send"
	"micagoserver/internal/store"
)

func TestListChats(t *testing.T) {
	db := openTestDB(t)
	seedRelayData(t, db)

	chats, err := db.ListChats(context.Background(), 10, 0, false, "iMessage", false)
	if err != nil {
		t.Fatal(err)
	}
	if len(chats) != 1 {
		t.Fatalf("expected 1 non-archived iMessage chat, got %d", len(chats))
	}
	if chats[0].GUID != "chat-1" {
		t.Fatalf("expected chat-1, got %q", chats[0].GUID)
	}

	// debug=true reveals all chats including the message-less one.
	allChats, err := db.ListChats(context.Background(), 10, 0, true, "all", true)
	if err != nil {
		t.Fatal(err)
	}
	if len(allChats) != 3 {
		t.Fatalf("expected 3 chats, got %d", len(allChats))
	}
}

func TestListChatsMarksGroupChats(t *testing.T) {
	db := openTestDB(t)
	if _, err := db.sqlDB.Exec(`
INSERT INTO chats (guid, chat_identifier, service_name, display_name, is_archived, style, participant_count, updated_at) VALUES
('any;-;+15551234567', '+15551234567', 'iMessage', '', 0, 45, 1, 100),
('any;+;guid-fallback', 'guid-fallback', 'iMessage', '', 0, NULL, 0, 90),
('style-group', 'style-group', 'iMessage', '', 0, 43, 1, 80),
('participant-group', 'participant-group', 'iMessage', '', 0, 45, 2, 70);
`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.sqlDB.Exec(`UPDATE chats SET participants = 'alice@example.com' || char(31) || '+15551234567' WHERE guid = 'participant-group'`); err != nil {
		t.Fatal(err)
	}

	chats, err := db.ListChats(context.Background(), 20, 0, true, "all", true)
	if err != nil {
		t.Fatal(err)
	}
	byGUID := map[string]store.ChatJSON{}
	for _, chat := range chats {
		byGUID[chat.GUID] = chat
	}
	if byGUID["any;-;+15551234567"].IsGroup {
		t.Fatal("direct chat marked as group")
	}
	for _, guid := range []string{"any;+;guid-fallback", "style-group", "participant-group"} {
		if !byGUID[guid].IsGroup {
			t.Fatalf("%s not marked as group: %+v", guid, byGUID[guid])
		}
	}
	gotParticipants := byGUID["participant-group"].Participants
	if len(gotParticipants) != 2 || gotParticipants[0] != "alice@example.com" || gotParticipants[1] != "+15551234567" {
		t.Fatalf("participants = %#v", gotParticipants)
	}
}

func TestListRecentMessages(t *testing.T) {
	db := openTestDB(t)
	seedRelayData(t, db)

	messages, err := db.ListRecentMessages(context.Background(), 10, 0, "iMessage", false)
	if err != nil {
		t.Fatal(err)
	}
	if len(messages) != 2 {
		t.Fatalf("expected 2 iMessage messages, got %d", len(messages))
	}
	if messages[0].GUID != "msg-2" {
		t.Fatalf("expected newest iMessage msg-2, got %q", messages[0].GUID)
	}
	if len(messages[0].Attachments) != 1 {
		t.Fatalf("expected 1 attachment for msg-2, got %d", len(messages[0].Attachments))
	}

	smsMessages, err := db.ListRecentMessages(context.Background(), 10, 0, "SMS", false)
	if err != nil {
		t.Fatal(err)
	}
	if len(smsMessages) != 1 {
		t.Fatalf("expected 1 SMS relay message, got %d", len(smsMessages))
	}
}

func TestGetAttachmentByGUID(t *testing.T) {
	db := openTestDB(t)
	seedRelayData(t, db)

	meta, err := db.GetAttachmentByGUID(context.Background(), "att-1")
	if err != nil {
		t.Fatal(err)
	}
	if meta == nil {
		t.Fatal("expected attachment metadata")
	}
	if meta.MessageGUID != "msg-2" {
		t.Fatalf("expected msg-2, got %q", meta.MessageGUID)
	}
}

func TestListChatMessagesAndExists(t *testing.T) {
	db := openTestDB(t)
	seedRelayData(t, db)

	exists, err := db.ChatExists(context.Background(), "chat-1")
	if err != nil {
		t.Fatal(err)
	}
	if !exists {
		t.Fatal("expected chat-1 to exist")
	}

	messages, err := db.ListChatMessages(context.Background(), "chat-1", 10, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(messages) != 2 {
		t.Fatalf("expected 2 messages for chat-1, got %d", len(messages))
	}
	if messages[0].GUID != "msg-2" {
		t.Fatalf("expected newest msg-2, got %q", messages[0].GUID)
	}
}

func TestListMergedMessagesUsesStableRouteCursor(t *testing.T) {
	db := openTestDB(t)
	if _, err := db.sqlDB.Exec(`
INSERT INTO chats (guid, chat_identifier, service_name, is_archived, updated_at) VALUES
('route-a', 'a@example.com', 'iMessage', 0, 4000),
('route-b', '+15550100', 'iMessage', 0, 3000);
INSERT INTO messages (guid, chat_guid, source_rowid, text, service, date_created, is_from_me, is_read, is_delivered, created_at) VALUES
('m1', 'route-a', 1, 'one',   'iMessage', 1000, 0, 1, 1, 1000),
('m2', 'route-b', 2, 'two',   'iMessage', 2000, 0, 1, 1, 2000),
('m3', 'route-a', 3, 'three', 'iMessage', 3000, 0, 1, 1, 3000),
('m4', 'route-b', 4, 'four',  'iMessage', 4000, 0, 1, 1, 4000);
`); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	first, err := db.ListMergedMessages(ctx, []string{"route-a", "route-b"}, 2, nil, nil, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(first) != 2 || first[0].GUID != "m4" || first[1].GUID != "m3" {
		t.Fatalf("first page = %#v", first)
	}
	second, err := db.ListMergedMessages(ctx, []string{"route-a", "route-b"}, 2, first[1].DateCreated, first[1].SourceRowID, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(second) != 2 || second[0].GUID != "m2" || second[1].GUID != "m1" {
		t.Fatalf("second page = %#v", second)
	}
}

func TestFindOutgoingMessageMatch(t *testing.T) {
	db := openTestDB(t)
	seedRelayData(t, db)

	match, err := db.FindOutgoingMessageMatch(context.Background(), "chat-1", "world", 1500, nil)
	if err != nil {
		t.Fatal(err)
	}
	if match == nil {
		t.Fatal("expected outgoing match")
	}
	if match.GUID != "msg-2" {
		t.Fatalf("expected msg-2, got %q", match.GUID)
	}
}

func TestFindOutgoingMessageMatchExcludesClaimedRow(t *testing.T) {
	db := openTestDB(t)
	seedRelayData(t, db)

	// Excluding the only matching row must yield no match (so a second
	// concurrent identical send won't re-confirm an already-claimed message).
	excluded := map[string]struct{}{"msg-2": {}}
	match, err := db.FindOutgoingMessageMatch(context.Background(), "chat-1", "world", 1500, excluded)
	if err != nil {
		t.Fatal(err)
	}
	if match != nil {
		t.Fatalf("expected no match when row is excluded, got %q", match.GUID)
	}
}

// Apple marks a rich link's internal preview parts (thumbnail, favicon,
// LinkPresentation payload) with hide_attachment=1 so they never show as
// standalone attachments. They were leaking into the client as 2–4 small "file"
// cards above the link; the messages API must exclude them (the debug view does).
func TestListChatMessagesExcludesHiddenAttachments(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	stmts := []string{
		`INSERT INTO chats (guid, chat_identifier, service_name, display_name, is_archived, updated_at) VALUES ('chat-L','cL','iMessage','Links',0,100)`,
		`INSERT INTO messages (guid, chat_guid, source_rowid, text, service, date_created, is_from_me, is_read, is_delivered, cache_has_attachments, created_at) VALUES ('m-link','chat-L',20,'https://example.com','iMessage',2000,0,1,1,1,100)`,
		`INSERT INTO attachments (guid, message_guid, filename, mime_type, transfer_name, total_bytes, is_outgoing, hide_attachment, created_at) VALUES
			('a-thumb','m-link','thumb.png','image/png','thumb.png',2048,0,1,100),
			('a-payload','m-link',NULL,NULL,'pluginPayload',512,0,1,100),
			('a-photo','m-link','photo.jpg','image/jpeg','photo.jpg',50000,0,0,100)`,
	}
	for _, s := range stmts {
		if _, err := db.sqlDB.Exec(s); err != nil {
			t.Fatal(err)
		}
	}

	msgs, err := db.ListChatMessages(ctx, "chat-L", 10, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 1 {
		t.Fatalf("expected 1 message, got %d", len(msgs))
	}
	got := msgs[0].Attachments
	if len(got) != 1 || got[0].GUID != "a-photo" {
		guids := make([]string, len(got))
		for i, a := range got {
			guids[i] = a.GUID
		}
		t.Fatalf("hidden link-preview attachments leaked; expected only [a-photo], got %v", guids)
	}
}

func TestListChatMessagesDedupesDuplicateAttachmentFiles(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	stmts := []string{
		`INSERT INTO chats (guid, chat_identifier, service_name, display_name, is_archived, updated_at) VALUES ('chat-D','cD','iMessage','Dupes',0,100)`,
		`INSERT INTO messages (guid, chat_guid, source_rowid, text, service, date_created, is_from_me, is_read, is_delivered, cache_has_attachments, created_at) VALUES ('m-d','chat-D',30,NULL,'iMessage',3000,0,1,1,1,100)`,
		// Two attachment rows (distinct guids) for the SAME file + one genuinely
		// different file. The same-file pair must collapse to one (C49).
		`INSERT INTO attachments (guid, message_guid, filename, mime_type, transfer_name, total_bytes, is_outgoing, hide_attachment, created_at) VALUES
			('a-dup-1','m-d','IMG_1.HEIC','image/heic','IMG_1.HEIC',12345,0,0,100),
			('a-dup-2','m-d','IMG_1.HEIC','image/heic','IMG_1.HEIC',12345,0,0,101),
			('a-other','m-d','clip.m4a','audio/x-m4a','clip.m4a',900,0,0,102)`,
	}
	for _, s := range stmts {
		if _, err := db.sqlDB.Exec(s); err != nil {
			t.Fatal(err)
		}
	}

	msgs, err := db.ListChatMessages(ctx, "chat-D", 10, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 1 {
		t.Fatalf("expected 1 message, got %d", len(msgs))
	}
	got := msgs[0].Attachments
	if len(got) != 2 {
		guids := make([]string, len(got))
		for i, a := range got {
			guids[i] = a.GUID
		}
		t.Fatalf("expected 2 attachments after dedupe, got %d: %v", len(got), guids)
	}
	// The first of the duplicate pair (by created_at, then guid) is kept.
	if got[0].GUID != "a-dup-1" || got[1].GUID != "a-other" {
		t.Fatalf("unexpected attachments: %s, %s", got[0].GUID, got[1].GUID)
	}
}

func TestListChatMessagesVideoGetsPosterPreviewURL(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	stmts := []string{
		`INSERT INTO chats (guid, chat_identifier, service_name, display_name, is_archived, updated_at) VALUES ('chat-V','cV','iMessage','Vids',0,100)`,
		`INSERT INTO messages (guid, chat_guid, source_rowid, text, service, date_created, is_from_me, is_read, is_delivered, cache_has_attachments, created_at) VALUES ('m-v','chat-V',40,NULL,'iMessage',4000,0,1,1,1,100)`,
		`INSERT INTO attachments (guid, message_guid, filename, mime_type, transfer_name, total_bytes, is_outgoing, hide_attachment, created_at) VALUES
			('a-vid','m-v','clip.mp4','video/mp4','clip.mp4',999999,0,0,100)`,
	}
	for _, s := range stmts {
		if _, err := db.sqlDB.Exec(s); err != nil {
			t.Fatal(err)
		}
	}
	msgs, err := db.ListChatMessages(ctx, "chat-V", 10, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 1 || len(msgs[0].Attachments) != 1 {
		t.Fatalf("expected 1 message with 1 attachment, got %d msgs", len(msgs))
	}
	got := msgs[0].Attachments[0]
	// C53: videos expose a Quick Look poster frame via /preview so the client
	// renders a thumbnail instead of trying to decode raw mp4 bytes as an image.
	if got.PreviewURL != "/api/attachments/a-vid/preview" {
		t.Fatalf("video previewUrl = %q, want the /preview poster route", got.PreviewURL)
	}
}

func seedRelayData(t *testing.T, db *DB) {
	t.Helper()
	tx, err := db.sqlDB.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()

	_, err = tx.Exec(`
INSERT INTO chats (guid, chat_identifier, service_name, display_name, is_archived, updated_at) VALUES
('chat-1', 'c1', 'iMessage', 'Chat 1', 0, 100),
('chat-2', 'c2', 'iMessage', 'Chat 2', 1, 90),
('chat-3', 'c3', 'SMS', 'Chat 3', 0, 80);
`)
	if err != nil {
		t.Fatal(err)
	}

	_, err = tx.Exec(`
INSERT INTO messages (
	guid, chat_guid, source_rowid, text, subject, service, date_created, date_read, date_delivered,
	is_from_me, is_read, is_delivered, handle_id, handle_service, cache_has_attachments, created_at
) VALUES
('msg-1', 'chat-1', 10, 'hello', NULL, 'iMessage', 1000, NULL, NULL, 0, 1, 1, 'h1', 'iMessage', 0, 100),
('msg-2', 'chat-1', 11, 'world', NULL, 'iMessage', 2000, NULL, NULL, 1, 1, 1, 'h1', 'iMessage', 1, 100),
('msg-3', 'chat-3', 12, 'sms', NULL, 'SMS', 1500, NULL, NULL, 0, 1, 1, 'h2', 'SMS', 0, 100);
`)
	if err != nil {
		t.Fatal(err)
	}

	_, err = tx.Exec(`
INSERT INTO attachments (
	guid, message_guid, filename, mime_type, transfer_name, total_bytes, local_path, is_outgoing, hide_attachment, created_at
) VALUES
('att-1', 'msg-2', 'photo.jpg', 'image/jpeg', 'photo.jpg', 1234, '/tmp/photo.jpg', 1, 0, 100);
`)
	if err != nil {
		t.Fatal(err)
	}

	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
}

func TestFindOutgoingMessageMatchOrdersEarliestFirst(t *testing.T) {
	db := openTestDB(t)
	if _, err := db.sqlDB.Exec(`
INSERT INTO chats (guid, chat_identifier, service_name, display_name, is_archived, updated_at) VALUES
('chat-dup', 'c1', 'iMessage', 'Dup', 0, 100);
INSERT INTO messages (
	guid, chat_guid, source_rowid, text, service, date_created, is_from_me, is_read, is_delivered, cache_has_attachments, created_at
) VALUES
('msg-early', 'chat-dup', 101, 'same text', 'iMessage', 1020, 1, 1, 1, 0, 1020),
('msg-late', 'chat-dup', 102, 'same text', 'iMessage', 1060, 1, 1, 1, 0, 1060);
`); err != nil {
		t.Fatal(err)
	}

	ctx := context.Background()
	normalized := send.NormalizeText("same text")
	excluded := map[string]struct{}{}

	matchA, err := db.FindOutgoingMessageMatch(ctx, "chat-dup", normalized, 1000, excluded)
	if err != nil {
		t.Fatal(err)
	}
	if matchA == nil || matchA.GUID != "msg-early" {
		t.Fatalf("Send A should match earliest msg-early, got %+v", matchA)
	}

	excluded[matchA.GUID] = struct{}{}
	matchB, err := db.FindOutgoingMessageMatch(ctx, "chat-dup", normalized, 1050, excluded)
	if err != nil {
		t.Fatal(err)
	}
	if matchB == nil || matchB.GUID != "msg-late" {
		t.Fatalf("Send B should match msg-late, got %+v", matchB)
	}
}

func TestGetMessagesByGUIDsChunksLargeBatchesAndPreservesOrder(t *testing.T) {
	db := openTestDB(t)
	tx, err := db.sqlDB.Begin()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(`INSERT INTO chats (guid, chat_identifier, service_name, display_name, is_archived, updated_at) VALUES ('chat-bulk', 'bulk', 'iMessage', 'Bulk', 0, 100)`); err != nil {
		t.Fatal(err)
	}
	// Include one message with NULL source_rowid to verify NULL sorts first under ASC.
	if _, err := tx.Exec(`INSERT INTO messages (guid, chat_guid, source_rowid, text, service, date_created, is_from_me, is_read, is_delivered, cache_has_attachments, created_at) VALUES ('msg-null-rowid', 'chat-bulk', NULL, 'null rowid', 'iMessage', 50, 0, 1, 1, 0, 50)`); err != nil {
		t.Fatal(err)
	}
	const total = 1205
	guids := make([]string, 0, total+5)
	guids = append(guids, "msg-null-rowid")
	for i := total; i >= 1; i-- {
		guid := fmt.Sprintf("msg-%04d", i)
		if _, err := tx.Exec(`INSERT INTO messages (guid, chat_guid, source_rowid, text, service, date_created, is_from_me, is_read, is_delivered, cache_has_attachments, created_at) VALUES (?, 'chat-bulk', ?, 'hello', 'iMessage', ?, 0, 1, 1, 1, ?)`, guid, i, i*10, i*10); err != nil {
			t.Fatal(err)
		}
		if i == 1 || i == 600 || i == total {
			if _, err := tx.Exec(`INSERT INTO attachments (guid, message_guid, filename, mime_type, transfer_name, total_bytes, local_path, is_outgoing, hide_attachment, created_at) VALUES (?, ?, 'pic.jpg', 'image/jpeg', 'pic.jpg', 100, '/tmp/pic.jpg', 0, 0, 10)`, fmt.Sprintf("att-%d-a", i), guid); err != nil {
				t.Fatal(err)
			}
			// Duplicate file identity on the same message must still dedupe across chunks.
			if _, err := tx.Exec(`INSERT INTO attachments (guid, message_guid, filename, mime_type, transfer_name, total_bytes, local_path, is_outgoing, hide_attachment, created_at) VALUES (?, ?, 'pic.jpg', 'image/jpeg', 'pic.jpg', 100, '/tmp/pic.jpg', 0, 0, 11)`, fmt.Sprintf("att-%d-b", i), guid); err != nil {
				t.Fatal(err)
			}
		}
		guids = append(guids, guid)
	}
	// Add duplicate GUIDs in input to ensure deduping works.
	guids = append(guids, "msg-0001", "msg-0600")
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}

	got, err := db.GetMessagesByGUIDs(context.Background(), guids)
	if err != nil {
		t.Fatalf("GetMessagesByGUIDs failed on %d GUIDs: %v", len(guids), err)
	}
	if len(got) != total+1 {
		t.Fatalf("expected %d messages, got %d", total+1, len(got))
	}
	if got[0].GUID != "msg-null-rowid" {
		t.Fatalf("expected NULL source_rowid first, got %q", got[0].GUID)
	}
	if got[1].GUID != "msg-0001" || got[len(got)-1].GUID != fmt.Sprintf("msg-%04d", total) {
		t.Fatalf("unexpected ordering: first=%q last=%q", got[1].GUID, got[len(got)-1].GUID)
	}
	for _, idx := range []int{1, 600, total} {
		if len(got[idx].Attachments) != 1 {
			t.Fatalf("expected 1 deduped attachment for %s, got %d", got[idx].GUID, len(got[idx].Attachments))
		}
	}
}

func TestListChatsAndAttachmentsTolerateNullColumns(t *testing.T) {
	db := openTestDB(t)
	if _, err := db.sqlDB.Exec(`
INSERT INTO chats (guid, chat_identifier, service_name, display_name, is_archived, updated_at) VALUES
('chat-null-archived', 'c-null', 'iMessage', 'Null Archived', NULL, 100);
INSERT INTO messages (guid, chat_guid, source_rowid, text, service, date_created, is_from_me, is_read, is_delivered, cache_has_attachments, created_at) VALUES
('msg-null-att', 'chat-null-archived', 1, 'with att', 'iMessage', 1000, 0, 1, 1, 1, 1000);
INSERT INTO attachments (guid, message_guid, filename, mime_type, transfer_name, total_bytes, local_path, is_outgoing, hide_attachment, created_at, is_sticker) VALUES
('att-nulls', 'msg-null-att', 'file.bin', 'application/octet-stream', 'file.bin', NULL, '/tmp/file.bin', NULL, NULL, 1000, NULL);
`); err != nil {
		t.Fatal(err)
	}

	ctx := context.Background()
	chats, err := db.ListChats(ctx, 10, 0, false, "all", false)
	if err != nil {
		t.Fatalf("ListChats with NULL is_archived: %v", err)
	}
	if len(chats) != 1 || chats[0].GUID != "chat-null-archived" || chats[0].IsArchived {
		t.Fatalf("unexpected chats: %+v", chats)
	}

	meta, err := db.GetAttachmentByGUID(ctx, "att-nulls")
	if err != nil {
		t.Fatalf("GetAttachmentByGUID with NULL columns: %v", err)
	}
	if meta == nil || meta.TotalBytes != 0 || meta.IsOutgoing || meta.HideAttachment || meta.IsSticker {
		t.Fatalf("unexpected attachment meta: %+v", meta)
	}

	msgs, err := db.GetMessagesByGUIDs(ctx, []string{"msg-null-att"})
	if err != nil {
		t.Fatalf("GetMessagesByGUIDs with NULL attachment total_bytes: %v", err)
	}
	if len(msgs) != 1 || len(msgs[0].Attachments) != 1 || msgs[0].Attachments[0].TotalBytes != 0 {
		t.Fatalf("unexpected message attachments: %+v", msgs)
	}
}

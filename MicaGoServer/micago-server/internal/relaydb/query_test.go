package relaydb

import (
	"context"
	"testing"

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

package relaydb

import (
	"context"
	"testing"
	"time"

	"micagoserver/internal/store"
)

// writeAvoidanceSource simulates the steady state that used to churn: the
// ROWID query returns nothing new, while the date-lookback window re-feeds the
// same already-synced rows (and their attachments) on every pass.
type writeAvoidanceSource struct {
	chats       []store.SyncChatRow
	dateRows    []store.SyncMessageRow
	attachments map[string][]store.SyncAttachmentRow
}

func (s *writeAvoidanceSource) ListSyncChats(context.Context) ([]store.SyncChatRow, error) {
	return s.chats, nil
}
func (s *writeAvoidanceSource) ListSyncRecentMessages(context.Context, int) ([]store.SyncMessageRow, error) {
	return nil, nil
}
func (s *writeAvoidanceSource) ListSyncRecentMessagesSince(context.Context, int64, int) ([]store.SyncMessageRow, error) {
	return nil, nil
}
func (s *writeAvoidanceSource) ListSyncRecentMessagesByDate(context.Context, int64, int) ([]store.SyncMessageRow, error) {
	return s.dateRows, nil
}
func (s *writeAvoidanceSource) ListSyncAttachmentsForMessages(_ context.Context, messageGUIDs []string) ([]store.SyncAttachmentRow, error) {
	var rows []store.SyncAttachmentRow
	for _, guid := range messageGUIDs {
		rows = append(rows, s.attachments[guid]...)
	}
	return rows, nil
}

func writeAvoidanceFixture() *writeAvoidanceSource {
	return &writeAvoidanceSource{
		chats: []store.SyncChatRow{{
			GUID:           "c",
			ChatIdentifier: strp("+15550001111"),
			ServiceName:    strp("iMessage"),
			DisplayName:    strp("Alice"),
		}},
		dateRows: []store.SyncMessageRow{
			{ChatGUID: "c", SourceRowID: 90, GUID: "m-1", Text: strp("hello"), DateCreated: intp(1700)},
			{ChatGUID: "c", SourceRowID: 95, GUID: "m-2", Text: strp("photo"), DateCreated: intp(1800), CacheHasAttachments: true},
		},
		attachments: map[string][]store.SyncAttachmentRow{
			"m-2": {{
				GUID:        "att-1",
				MessageGUID: "m-2",
				Filename:    strp("~/Library/Messages/Attachments/x/IMG_1.heic"),
				MimeType:    strp("image/heic"),
				TotalBytes:  1234,
				// CreatedAt nil on purpose: these rows used the `now` fallback and
				// were rewritten (with a moving created_at) on every sync.
			}},
		},
	}
}

// C57: re-syncing identical data must not write anything — the DO UPDATE diff
// skips unchanged rows, chats.updated_at stays put, and the attachment
// created_at fallback stops moving.
func TestSyncOnceSkipsUnchangedRows(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	_ = db.SetSyncState("last_message_rowid", "100")
	src := writeAvoidanceFixture()

	first, err := SyncOnce(ctx, src, db, 200, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if first.MessagesWritten != 2 || first.ChatsWritten != 1 || first.AttachmentsWritten != 1 {
		t.Fatalf("first sync should write everything, got %+v", first)
	}
	if !first.LookbackApplied {
		t.Fatal("first sync should report the lookback scan ran")
	}

	var updatedAt, attCreatedAt int64
	if err := db.sqlDB.QueryRow(`SELECT updated_at FROM chats WHERE guid = 'c'`).Scan(&updatedAt); err != nil {
		t.Fatal(err)
	}
	if err := db.sqlDB.QueryRow(`SELECT created_at FROM attachments WHERE guid = 'att-1'`).Scan(&attCreatedAt); err != nil {
		t.Fatal(err)
	}

	time.Sleep(2 * time.Millisecond) // ensure a later `now` would be observable
	second, err := SyncOnce(ctx, src, db, 200, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if second.MessagesWritten != 0 || second.ChatsWritten != 0 || second.AttachmentsWritten != 0 {
		t.Fatalf("identical re-sync must write nothing, got chats=%d messages=%d attachments=%d",
			second.ChatsWritten, second.MessagesWritten, second.AttachmentsWritten)
	}
	if second.MessagesUnchanged != 2 || second.ChatsUnchanged != 1 || second.AttachmentsUnchanged != 1 {
		t.Fatalf("unchanged counters wrong: %+v", second)
	}
	if len(second.NewMessages) != 0 {
		t.Fatalf("re-sync must not re-broadcast, got %d", len(second.NewMessages))
	}

	var updatedAt2, attCreatedAt2 int64
	if err := db.sqlDB.QueryRow(`SELECT updated_at FROM chats WHERE guid = 'c'`).Scan(&updatedAt2); err != nil {
		t.Fatal(err)
	}
	if err := db.sqlDB.QueryRow(`SELECT created_at FROM attachments WHERE guid = 'att-1'`).Scan(&attCreatedAt2); err != nil {
		t.Fatal(err)
	}
	if updatedAt2 != updatedAt {
		t.Fatalf("unchanged chat's updated_at moved: %d -> %d", updatedAt, updatedAt2)
	}
	if attCreatedAt2 != attCreatedAt {
		t.Fatalf("unchanged attachment's created_at moved: %d -> %d", attCreatedAt, attCreatedAt2)
	}
}

// Real changes must still be written: a read-state flip on a message and a
// renamed chat update exactly those rows and nothing else.
func TestSyncOnceWritesChangedRows(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	_ = db.SetSyncState("last_message_rowid", "100")
	src := writeAvoidanceFixture()

	if _, err := SyncOnce(ctx, src, db, 200, time.Hour); err != nil {
		t.Fatal(err)
	}

	src.dateRows[0].IsRead = true
	src.chats[0].DisplayName = strp("Alice Chen")
	third, err := SyncOnce(ctx, src, db, 200, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if third.MessagesWritten != 1 || third.MessagesUnchanged != 1 {
		t.Fatalf("expected exactly the read-flipped message written, got %+v", third)
	}
	if third.ChatsWritten != 1 {
		t.Fatalf("expected renamed chat written, got %+v", third)
	}
	if third.AttachmentsWritten != 0 || third.AttachmentsUnchanged != 1 {
		t.Fatalf("attachment should be untouched, got %+v", third)
	}
	if len(third.NewMessages) != 0 {
		t.Fatal("an update must not re-broadcast as new")
	}

	var isRead int
	if err := db.sqlDB.QueryRow(`SELECT is_read FROM messages WHERE guid = 'm-1'`).Scan(&isRead); err != nil {
		t.Fatal(err)
	}
	if isRead != 1 {
		t.Fatal("read flip not persisted")
	}
	var displayName string
	if err := db.sqlDB.QueryRow(`SELECT display_name FROM chats WHERE guid = 'c'`).Scan(&displayName); err != nil {
		t.Fatal(err)
	}
	if displayName != "Alice Chen" {
		t.Fatalf("rename not persisted: %q", displayName)
	}
}

// With lookback 0 (the throttled steady-state trigger), the date scan is
// skipped and reported as such; the rowid path still works.
func TestSyncOnceLookbackZeroSkipsDateScan(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	_ = db.SetSyncState("last_message_rowid", "100")
	src := writeAvoidanceFixture()

	res, err := SyncOnce(ctx, src, db, 200, 0)
	if err != nil {
		t.Fatal(err)
	}
	if res.LookbackApplied {
		t.Fatal("lookback 0 must not run the date scan")
	}
	if res.MessagesSynced != 0 {
		t.Fatalf("rowid query returned nothing; expected 0 synced, got %d", res.MessagesSynced)
	}
}

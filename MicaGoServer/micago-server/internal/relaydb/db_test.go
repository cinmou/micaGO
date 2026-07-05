package relaydb

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"

	_ "github.com/mattn/go-sqlite3"

	"micagoserver/internal/store"
)

func openTestDB(t *testing.T) *DB {
	t.Helper()
	db, err := Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatalf("open relay db: %v", err)
	}
	t.Cleanup(func() {
		_ = db.Close()
	})
	return db
}

func TestMigrateCreatesTables(t *testing.T) {
	db := openTestDB(t)

	for _, table := range []string{"chats", "messages", "attachments", "sync_state", "devices"} {
		var name string
		err := db.sqlDB.QueryRow(`SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?`, table).Scan(&name)
		if err != nil {
			t.Fatalf("expected table %s: %v", table, err)
		}
	}

	var sourceRowIDColumn string
	err := db.sqlDB.QueryRow(`SELECT name FROM pragma_table_info('messages') WHERE name = 'source_rowid'`).Scan(&sourceRowIDColumn)
	if err != nil {
		t.Fatalf("expected source_rowid column: %v", err)
	}
}

func TestDeviceUpsertListDelete(t *testing.T) {
	db := openTestDB(t)
	now := int64(123)
	record := store.DeviceRecord{
		ID:           "dev-1",
		Name:         "Android",
		Platform:     "android",
		ClientType:   "flutter",
		PushProvider: "fcm",
		PushEnabled:  true,
		PushToken:    ptr("secret-token"),
		LastSeenAt:   &now,
		CreatedAt:    now,
		UpdatedAt:    now,
	}

	saved, err := db.UpsertDevice(context.Background(), record)
	if err != nil {
		t.Fatal(err)
	}
	if saved.PushToken == nil || *saved.PushToken != "secret-token" {
		t.Fatalf("expected push token to be stored, got %#v", saved.PushToken)
	}

	devices, err := db.ListDevices(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(devices) != 1 {
		t.Fatalf("expected 1 device, got %d", len(devices))
	}

	if err := db.DeleteDevice(context.Background(), "dev-1"); err != nil {
		t.Fatal(err)
	}
	devices, err = db.ListDevices(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(devices) != 0 {
		t.Fatalf("expected 0 devices, got %d", len(devices))
	}
}

// C21u: re-registering the same stable device id must update the existing row
// (mode/version/last-seen) rather than create duplicates.
func TestDeviceReregisterUpsertsNoDuplicates(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()

	first := store.DeviceRecord{
		ID: "flutter-stable", Name: "Pixel", Platform: "android",
		ClientType: "flutter", AppVersion: "0.1.0", Mode: "lan",
		PushProvider: "none", LastSeenAt: ptrInt(100), CreatedAt: 100, UpdatedAt: 100,
	}
	if _, err := db.UpsertDevice(ctx, first); err != nil {
		t.Fatal(err)
	}

	// Same id, later reconnect: mode flips to lan_public, last-seen advances.
	second := first
	second.Mode = "lan_public"
	second.LastSeenAt = ptrInt(500)
	second.UpdatedAt = 500
	if _, err := db.UpsertDevice(ctx, second); err != nil {
		t.Fatal(err)
	}

	devices, err := db.ListDevices(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(devices) != 1 {
		t.Fatalf("expected 1 device after re-register, got %d", len(devices))
	}
	got := devices[0]
	if got.Mode != "lan_public" || got.AppVersion != "0.1.0" {
		t.Fatalf("expected updated mode/version, got mode=%q version=%q", got.Mode, got.AppVersion)
	}
	if got.LastSeenAt == nil || *got.LastSeenAt != 500 {
		t.Fatalf("expected last-seen 500, got %v", got.LastSeenAt)
	}
}

func ptrInt(v int64) *int64 { return &v }

// C22: an FCM token refresh on the same stable device id updates the existing
// row (no duplicate), and the new token + push/background flags are persisted.
func TestDeviceTokenRefreshUpdatesSameRow(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()

	base := store.DeviceRecord{
		ID: "flutter-stable", Name: "Pixel", Platform: "android", ClientType: "flutter",
		PushProvider: "fcm", PushEnabled: true, Background: true,
		PushToken:  ptr("token-A"),
		LastSeenAt: ptrInt(100), CreatedAt: 100, UpdatedAt: 100,
	}
	if _, err := db.UpsertDevice(ctx, base); err != nil {
		t.Fatal(err)
	}

	refreshed := base
	refreshed.PushToken = ptr("token-B")
	refreshed.UpdatedAt = 200
	if _, err := db.UpsertDevice(ctx, refreshed); err != nil {
		t.Fatal(err)
	}

	devices, err := db.ListDevices(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(devices) != 1 {
		t.Fatalf("expected 1 device after token refresh, got %d", len(devices))
	}
	got := devices[0]
	if got.PushToken == nil || *got.PushToken != "token-B" {
		t.Fatalf("expected refreshed token-B, got %v", got.PushToken)
	}
	if !got.PushEnabled || !got.Background || got.PushProvider != "fcm" {
		t.Fatalf("expected push+background enabled fcm, got %#v", got)
	}
}

func TestDeviceListAllowsLegacyNullBackground(t *testing.T) {
	db := openTestDB(t)
	ctx := context.Background()
	_, err := db.sqlDB.ExecContext(ctx, `
INSERT INTO devices (
	id, name, platform, client_type, app_version, mode, push_provider, push_token,
	push_enabled, background, last_seen_at, created_at, updated_at
) VALUES (
	'legacy-null-bg', 'Old Android', 'android', 'flutter', '', '', 'none', NULL,
	0, NULL, NULL, 100, 100
);
`)
	if err != nil {
		t.Fatal(err)
	}

	device, err := db.GetDeviceByID(ctx, "legacy-null-bg")
	if err != nil {
		t.Fatalf("get legacy device: %v", err)
	}
	if device == nil {
		t.Fatal("expected legacy device")
	}
	if device.Background {
		t.Fatalf("expected null background to read as false, got %#v", device)
	}

	devices, err := db.ListDevices(ctx)
	if err != nil {
		t.Fatalf("list legacy devices: %v", err)
	}
	if len(devices) != 1 || devices[0].Background {
		t.Fatalf("expected one legacy device with background=false, got %#v", devices)
	}
}

func TestUpsertDoesNotDuplicateRows(t *testing.T) {
	db := openTestDB(t)
	tx, err := db.sqlDB.Begin()
	if err != nil {
		t.Fatal(err)
	}

	chats := []store.SyncChatRow{{GUID: "chat-1"}}
	messages := []store.SyncMessageRow{{GUID: "msg-1", ChatGUID: "chat-1", SourceRowID: 42}}

	if _, _, err := upsertChatsTx(tx, chats, 100); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := upsertMessagesTx(tx, messages, 100); err != nil {
		t.Fatal(err)
	}
	if _, _, err := upsertChatsTx(tx, chats, 200); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := upsertMessagesTx(tx, messages, 200); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}

	assertCount(t, db.sqlDB, "SELECT COUNT(*) FROM chats", 1)
	assertCount(t, db.sqlDB, "SELECT COUNT(*) FROM messages", 1)

	var sourceRowID int64
	if err := db.sqlDB.QueryRow(`SELECT source_rowid FROM messages WHERE guid = 'msg-1'`).Scan(&sourceRowID); err != nil {
		t.Fatal(err)
	}
	if sourceRowID != 42 {
		t.Fatalf("expected source_rowid 42, got %d", sourceRowID)
	}
}

func TestSyncStateReadWrite(t *testing.T) {
	db := openTestDB(t)

	if err := db.SetSyncState("last_sync_at", "123"); err != nil {
		t.Fatal(err)
	}
	if err := db.SetSyncState("last_sync_at", "456"); err != nil {
		t.Fatal(err)
	}

	value, ok, err := db.GetSyncState("last_sync_at")
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("expected sync state to exist")
	}
	if value != "456" {
		t.Fatalf("expected updated value, got %q", value)
	}
}

func TestIncrementalSyncDoesNotDuplicateExistingMessages(t *testing.T) {
	db := openTestDB(t)
	source := &fakeSyncSource{
		chats: []store.SyncChatRow{{GUID: "chat-1"}},
		initialMessages: []store.SyncMessageRow{
			{GUID: "msg-1", ChatGUID: "chat-1", SourceRowID: 100},
		},
		incrementalMessages: map[int64][]store.SyncMessageRow{
			100: {
				{GUID: "msg-2", ChatGUID: "chat-1", SourceRowID: 101},
			},
			101: {},
		},
	}

	first, err := SyncOnce(t.Context(), source, db, 1000, 0)
	if err != nil {
		t.Fatal(err)
	}
	if first.Mode != "initial" {
		t.Fatalf("expected initial mode, got %q", first.Mode)
	}
	if first.NewLastMessageRowID != 100 {
		t.Fatalf("expected rowid 100, got %d", first.NewLastMessageRowID)
	}
	if len(first.NewMessages) != 1 || first.NewMessages[0].GUID != "msg-1" {
		t.Fatalf("expected first sync to return new msg-1, got %#v", first.NewMessages)
	}

	second, err := SyncOnce(t.Context(), source, db, 1000, 0)
	if err != nil {
		t.Fatal(err)
	}
	if second.Mode != "incremental" {
		t.Fatalf("expected incremental mode, got %q", second.Mode)
	}
	if second.NewLastMessageRowID != 101 {
		t.Fatalf("expected rowid 101, got %d", second.NewLastMessageRowID)
	}
	if len(second.NewMessages) != 1 || second.NewMessages[0].GUID != "msg-2" {
		t.Fatalf("expected second sync to return new msg-2, got %#v", second.NewMessages)
	}

	third, err := SyncOnce(t.Context(), source, db, 1000, 0)
	if err != nil {
		t.Fatal(err)
	}
	if third.NewLastMessageRowID != 101 {
		t.Fatalf("expected unchanged rowid 101, got %d", third.NewLastMessageRowID)
	}
	if len(third.NewMessages) != 0 {
		t.Fatalf("expected no new messages on third sync, got %#v", third.NewMessages)
	}

	assertCount(t, db.sqlDB, "SELECT COUNT(*) FROM messages", 2)

	value, ok, err := db.GetSyncState("last_message_rowid")
	if err != nil {
		t.Fatal(err)
	}
	if !ok || value != "101" {
		t.Fatalf("expected last_message_rowid 101, got ok=%v value=%q", ok, value)
	}
}

type fakeSyncSource struct {
	chats               []store.SyncChatRow
	initialMessages     []store.SyncMessageRow
	incrementalMessages map[int64][]store.SyncMessageRow
	attachments         map[string][]store.SyncAttachmentRow
}

func (f *fakeSyncSource) ListSyncChats(_ context.Context) ([]store.SyncChatRow, error) {
	return f.chats, nil
}

func (f *fakeSyncSource) ListSyncRecentMessages(_ context.Context, _ int) ([]store.SyncMessageRow, error) {
	return f.initialMessages, nil
}

func (f *fakeSyncSource) ListSyncRecentMessagesSince(_ context.Context, afterRowID int64, _ int) ([]store.SyncMessageRow, error) {
	return f.incrementalMessages[afterRowID], nil
}

func (f *fakeSyncSource) ListSyncAttachmentsForMessages(_ context.Context, messageGUIDs []string) ([]store.SyncAttachmentRow, error) {
	var rows []store.SyncAttachmentRow
	for _, guid := range messageGUIDs {
		rows = append(rows, f.attachments[guid]...)
	}
	return rows, nil
}

func assertCount(t *testing.T, db *sql.DB, query string, want int) {
	t.Helper()
	var got int
	if err := db.QueryRow(query).Scan(&got); err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("expected count %d, got %d", want, got)
	}
}

func ptr[T any](v T) *T { return &v }

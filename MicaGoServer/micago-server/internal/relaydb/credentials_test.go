package relaydb

import (
	"context"
	"micagoserver/internal/store"
	"path/filepath"
	"testing"
	"time"
)

func TestCredentialHashExpiryAndRevokedRegistration(t *testing.T) {
	db, err := Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ctx := context.Background()
	code, _, err := db.CreatePairingCode(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var hash string
	if err = db.sqlDB.QueryRow(`SELECT code_hash FROM pairing_codes`).Scan(&hash); err != nil || hash == code {
		t.Fatal("pairing code stored plaintext")
	}
	if _, err = db.sqlDB.Exec(`UPDATE pairing_codes SET expires_at=?`, time.Now().Add(-time.Minute).UnixMilli()); err != nil {
		t.Fatal(err)
	}
	if _, _, err = db.RedeemPairingCode(ctx, code); err == nil {
		t.Fatal("expired invitation accepted")
	}
	code, _, _ = db.CreatePairingCode(ctx)
	id, token, err := db.RedeemPairingCode(ctx, code)
	if err != nil {
		t.Fatal(err)
	}
	if err = db.sqlDB.QueryRow(`SELECT token_hash FROM device_credentials WHERE device_id=?`, id).Scan(&hash); err != nil || hash == token {
		t.Fatal("device token stored plaintext")
	}
	if err = db.RevokeDevice(ctx, id); err != nil {
		t.Fatal(err)
	}
	saved, err := db.UpsertDevice(ctx, store.DeviceRecord{ID: id, Name: "stale in-flight registration", Platform: "windows", ClientType: "native", PushProvider: "none"})
	if err != nil || saved != nil {
		t.Fatal("revoked registration resurrected presence/push row")
	}
}

func TestSecurityUpgradeStopsLegacyPush(t *testing.T) {
	db, err := Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ctx := context.Background()
	push := "test-only-push"
	if _, err = db.UpsertDevice(ctx, store.DeviceRecord{ID: "legacy", Name: "old phone", Platform: "android", ClientType: "flutter", PushProvider: "fcm", PushToken: &push, PushEnabled: true}); err != nil {
		t.Fatal(err)
	}
	code, _, _ := db.CreatePairingCode(ctx)
	id, _, err := db.RedeemPairingCode(ctx, code)
	if err != nil {
		t.Fatal(err)
	}
	if err = db.RemoveLegacyDevices(ctx); err != nil {
		t.Fatal(err)
	}
	devices, err := db.ListDevices(ctx)
	if err != nil || len(devices) != 1 || devices[0].ID != id {
		t.Fatal("legacy push registration retained or authorized device removed")
	}
}

func TestPairingStatusLifecycle(t *testing.T) {
	ctx := context.Background()
	db, err := Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	check := func(code, want string) {
		t.Helper()
		state, err := db.PairingCodeStatus(ctx, code)
		if err != nil || state != want {
			t.Fatalf("state=%s want=%s err=%v", state, want, err)
		}
	}
	code, _, err := db.CreatePairingCode(ctx)
	if err != nil {
		t.Fatal(err)
	}
	check(code, "active")
	if _, _, err := db.RedeemPairingCode(ctx, code); err != nil {
		t.Fatal(err)
	}
	check(code, "used")
	if _, _, err := db.RedeemPairingCode(ctx, code); err == nil {
		t.Fatal("used code redeemed twice")
	}
	// A used invitation remains used even after its original expiry.
	if _, err := db.sqlDB.Exec(`UPDATE pairing_codes SET expires_at=0`); err != nil {
		t.Fatal(err)
	}
	check(code, "used")
	next, _, err := db.CreatePairingCode(ctx)
	if err != nil {
		t.Fatal(err)
	}
	check(code, "invalidated")
	check(next, "active")
	if _, err := db.sqlDB.Exec(`UPDATE pairing_codes SET expires_at=0`); err != nil {
		t.Fatal(err)
	}
	check(next, "expired")
	if _, _, err := db.RedeemPairingCode(ctx, next); err == nil {
		t.Fatal("expired code redeemed")
	}
}

func TestPairingStatusMigratesExistingInvitations(t *testing.T) {
	path := filepath.Join(t.TempDir(), "relay.db")
	db, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.sqlDB.Exec(`DROP TABLE pairing_codes`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.sqlDB.Exec(`CREATE TABLE pairing_codes(code_hash TEXT PRIMARY KEY,expires_at INTEGER NOT NULL)`); err != nil {
		t.Fatal(err)
	}
	code := "test-migration-invitation"
	if _, err := db.sqlDB.Exec(`INSERT INTO pairing_codes VALUES(?,?)`, credentialHash(code), time.Now().Add(time.Minute).UnixMilli()); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	db, err = Open(path)
	if err != nil {
		t.Fatal(err)
	}
	state, err := db.PairingCodeStatus(context.Background(), code)
	if err != nil || state != "active" {
		t.Fatalf("migration: state=%s err=%v", state, err)
	}
	if _, _, err := db.RedeemPairingCode(context.Background(), code); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	db, err = Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	state, err = db.PairingCodeStatus(context.Background(), code)
	if err != nil || state != "used" {
		t.Fatalf("restart: state=%s err=%v", state, err)
	}
}

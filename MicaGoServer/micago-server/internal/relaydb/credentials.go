package relaydb

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"time"
)

func randomCredential() (string, error) {
	var b [32]byte
	_, err := rand.Read(b[:])
	return hex.EncodeToString(b[:]), err
}
func credentialHash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func (db *DB) CreatePairingCode(ctx context.Context) (string, int64, error) {
	code, err := randomCredential()
	if err != nil {
		return "", 0, err
	}
	expires := time.Now().Add(5 * time.Minute).UnixMilli()
	tx, err := db.sqlDB.BeginTx(ctx, nil)
	if err != nil {
		return "", 0, err
	}
	defer tx.Rollback()
	// One visible invitation at a time. Refreshing invalidates the previous QR.
	if _, err = tx.ExecContext(ctx, `DELETE FROM pairing_codes`); err != nil {
		return "", 0, err
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO pairing_codes(code_hash,expires_at) VALUES(?,?)`, credentialHash(code), expires); err != nil {
		return "", 0, err
	}
	return code, expires, tx.Commit()
}
func (db *DB) RedeemPairingCode(ctx context.Context, code string) (string, string, error) {
	token, err := randomCredential()
	if err != nil {
		return "", "", err
	}
	id, err := randomCredential()
	if err != nil {
		return "", "", err
	}
	id = "device-" + id[:32]
	tx, err := db.sqlDB.BeginTx(ctx, nil)
	if err != nil {
		return "", "", err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `UPDATE pairing_codes SET used=1 WHERE code_hash=? AND expires_at>? AND used=0`, credentialHash(code), time.Now().UnixMilli())
	if err != nil {
		return "", "", err
	}
	count, err := result.RowsAffected()
	if err != nil || count != 1 {
		return "", "", errors.New("pairing code expired or already used")
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO device_credentials(device_id,token_hash) VALUES(?,?)`, id, credentialHash(token)); err != nil {
		return "", "", err
	}
	now := time.Now().UnixMilli()
	if _, err = tx.ExecContext(ctx, `INSERT INTO devices(id,name,platform,client_type,push_provider,push_enabled,created_at,updated_at) VALUES(?, 'micaGO device', 'unknown', 'native', 'none',0,?,?)`, id, now, now); err != nil {
		return "", "", err
	}
	return id, token, tx.Commit()
}
func (db *DB) DeviceForToken(ctx context.Context, token string) (string, error) {
	var id string
	err := db.sqlDB.QueryRowContext(ctx, `SELECT device_id FROM device_credentials WHERE token_hash=? AND revoked=0`, credentialHash(token)).Scan(&id)
	return id, err
}
func (db *DB) RevokeDevice(ctx context.Context, id string) error {
	tx, err := db.sqlDB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, `UPDATE device_credentials SET revoked=1 WHERE device_id=?`, id); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, `DELETE FROM devices WHERE id=?`, id); err != nil {
		return err
	}
	return tx.Commit()
}

// RemoveLegacyDevices stops old shared-token installations receiving push
// previews after the security upgrade. Chat history and preference queues stay.
func (db *DB) RemoveLegacyDevices(ctx context.Context) error {
	_, err := db.sqlDB.ExecContext(ctx, `DELETE FROM devices WHERE NOT EXISTS(SELECT 1 FROM device_credentials WHERE device_id=devices.id AND revoked=0)`)
	return err
}

// PairingCodeStatus never returns the invitation or device credential.
func (db *DB) PairingCodeStatus(ctx context.Context, code string) (string, error) {
	var expires int64
	var used bool
	err := db.sqlDB.QueryRowContext(ctx, `SELECT expires_at,used FROM pairing_codes WHERE code_hash=?`, credentialHash(code)).Scan(&expires, &used)
	if errors.Is(err, sql.ErrNoRows) {
		return "invalidated", nil
	}
	if err != nil {
		return "", err
	}
	if used {
		return "used", nil
	}
	if expires <= time.Now().UnixMilli() {
		return "expired", nil
	}
	return "active", nil
}

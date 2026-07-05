package relaydb

import (
	"context"
	"database/sql"
	"time"

	"micagoserver/internal/store"
)

func (db *DB) UpsertDevice(ctx context.Context, device store.DeviceRecord) (*store.DeviceRecord, error) {
	_, err := db.sqlDB.ExecContext(ctx, `
INSERT INTO devices (
	id, name, platform, client_type, app_version, mode, push_provider, push_token, push_enabled, background, last_seen_at, created_at, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
	name = excluded.name,
	platform = excluded.platform,
	client_type = excluded.client_type,
	app_version = excluded.app_version,
	mode = excluded.mode,
	push_provider = excluded.push_provider,
	push_token = excluded.push_token,
	push_enabled = excluded.push_enabled,
	background = excluded.background,
	last_seen_at = excluded.last_seen_at,
	updated_at = excluded.updated_at;
`, device.ID, device.Name, device.Platform, device.ClientType, device.AppVersion, device.Mode, device.PushProvider, device.PushToken, boolToInt(device.PushEnabled), boolToInt(device.Background), device.LastSeenAt, device.CreatedAt, device.UpdatedAt)
	if err != nil {
		return nil, err
	}
	return db.GetDeviceByID(ctx, device.ID)
}

func (db *DB) GetDeviceByID(ctx context.Context, id string) (*store.DeviceRecord, error) {
	var device store.DeviceRecord
	var pushToken *string
	var appVersion, mode sql.NullString
	var lastSeenAt, background sql.NullInt64
	var pushEnabled int64
	err := db.sqlDB.QueryRowContext(ctx, `
SELECT id, name, platform, client_type, app_version, mode, push_provider, push_token, push_enabled, background, last_seen_at, created_at, updated_at
FROM devices
WHERE id = ?
LIMIT 1;
`, id).Scan(
		&device.ID,
		&device.Name,
		&device.Platform,
		&device.ClientType,
		&appVersion,
		&mode,
		&device.PushProvider,
		&pushToken,
		&pushEnabled,
		&background,
		&lastSeenAt,
		&device.CreatedAt,
		&device.UpdatedAt,
	)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	device.AppVersion = appVersion.String
	device.Mode = mode.String
	device.PushToken = pushToken
	device.PushEnabled = pushEnabled != 0
	device.Background = background.Valid && background.Int64 != 0
	if lastSeenAt.Valid {
		device.LastSeenAt = &lastSeenAt.Int64
	}
	return &device, nil
}

func (db *DB) ListDevices(ctx context.Context) ([]store.DeviceRecord, error) {
	rows, err := db.sqlDB.QueryContext(ctx, `
SELECT id, name, platform, client_type, app_version, mode, push_provider, push_token, push_enabled, background, last_seen_at, created_at, updated_at
FROM devices
ORDER BY updated_at DESC, created_at DESC, id ASC;
`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var devices []store.DeviceRecord
	for rows.Next() {
		var device store.DeviceRecord
		var pushToken *string
		var appVersion, mode sql.NullString
		var pushEnabled int64
		var background, lastSeenAt sql.NullInt64
		if err := rows.Scan(
			&device.ID,
			&device.Name,
			&device.Platform,
			&device.ClientType,
			&appVersion,
			&mode,
			&device.PushProvider,
			&pushToken,
			&pushEnabled,
			&background,
			&lastSeenAt,
			&device.CreatedAt,
			&device.UpdatedAt,
		); err != nil {
			return nil, err
		}
		device.AppVersion = appVersion.String
		device.Mode = mode.String
		device.PushToken = pushToken
		device.PushEnabled = pushEnabled != 0
		device.Background = background.Valid && background.Int64 != 0
		if lastSeenAt.Valid {
			device.LastSeenAt = &lastSeenAt.Int64
		}
		devices = append(devices, device)
	}
	return devices, rows.Err()
}

func (db *DB) PatchDevice(ctx context.Context, id string, patch store.DeviceRecord) (*store.DeviceRecord, error) {
	current, err := db.GetDeviceByID(ctx, id)
	if err != nil || current == nil {
		return current, err
	}
	if patch.Name != "" {
		current.Name = patch.Name
	}
	if patch.PushProvider != "" {
		current.PushProvider = patch.PushProvider
	}
	if patch.PushToken != nil {
		current.PushToken = patch.PushToken
	}
	current.PushEnabled = patch.PushEnabled
	current.UpdatedAt = patch.UpdatedAt
	return db.UpsertDevice(ctx, *current)
}

func (db *DB) UpdateDeviceHeartbeat(ctx context.Context, id string, at int64) (*store.DeviceRecord, error) {
	_, err := db.sqlDB.ExecContext(ctx, `
UPDATE devices
SET last_seen_at = ?, updated_at = ?
WHERE id = ?;
`, at, at, id)
	if err != nil {
		return nil, err
	}
	return db.GetDeviceByID(ctx, id)
}

func (db *DB) DeleteDevice(ctx context.Context, id string) error {
	_, err := db.sqlDB.ExecContext(ctx, `DELETE FROM devices WHERE id = ?`, id)
	return err
}

// ClearDevicePushToken removes a device's push token and disables push (v0.12),
// used to prune dead/unregistered FCM tokens reported by Google.
func (db *DB) ClearDevicePushToken(ctx context.Context, id string) error {
	_, err := db.sqlDB.ExecContext(ctx, `
UPDATE devices
SET push_token = NULL, push_enabled = 0, updated_at = ?
WHERE id = ?;
`, time.Now().UnixMilli(), id)
	return err
}

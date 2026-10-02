package relaydb

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
)

// nil means an older Companion has not published its pairing filter yet.
func (db *DB) HiddenLANEndpoints(ctx context.Context) ([]string, error) {
	var raw string
	err := db.sqlDB.QueryRowContext(ctx, "SELECT hidden_urls FROM lan_visibility WHERE id=1").Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var hidden []string
	err = json.Unmarshal([]byte(raw), &hidden)
	return hidden, err
}
func (db *DB) SetHiddenLANEndpoints(ctx context.Context, hidden []string) error {
	if hidden == nil {
		hidden = []string{}
	}
	raw, err := json.Marshal(hidden)
	if err != nil {
		return err
	}
	_, err = db.sqlDB.ExecContext(ctx, `INSERT INTO lan_visibility(id,hidden_urls) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET hidden_urls=excluded.hidden_urls WHERE lan_visibility.hidden_urls!=excluded.hidden_urls`, string(raw))
	return err
}

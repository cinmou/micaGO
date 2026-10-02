package relaydb

import (
	"context"
	"database/sql"
	"micagoserver/internal/store"
)

func readState(ctx context.Context, tx *sql.Tx) (store.ReadState, error) {
	result := store.ReadState{Data: []store.ReadPosition{}}
	if err := tx.QueryRowContext(ctx, "SELECT server_id FROM chat_preferences_state WHERE id=1").Scan(&result.ServerID); err != nil {
		return result, err
	}
	if err := tx.QueryRowContext(ctx, "SELECT revision FROM read_state WHERE id=1").Scan(&result.Revision); err != nil {
		return result, err
	}
	rows, err := tx.QueryContext(ctx, "SELECT chat_guid,read_through FROM read_positions ORDER BY chat_guid")
	if err != nil {
		return result, err
	}
	defer rows.Close()
	for rows.Next() {
		var row store.ReadPosition
		if err = rows.Scan(&row.ChatGUID, &row.ReadThrough); err != nil {
			return result, err
		}
		result.Data = append(result.Data, row)
	}
	return result, rows.Err()
}
func (db *DB) ReadState(ctx context.Context) (store.ReadState, error) {
	tx, err := db.sqlDB.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return store.ReadState{}, err
	}
	defer tx.Rollback()
	result, err := readState(ctx, tx)
	if err != nil {
		return result, err
	}
	return result, tx.Commit()
}

// MAX makes retries idempotent and concurrent/offline reads commutative.
func (db *DB) AdvanceReadState(ctx context.Context, request store.ReadStateMutation) (store.ReadState, error) {
	tx, err := db.sqlDB.BeginTx(ctx, nil)
	if err != nil {
		return store.ReadState{}, err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, "UPDATE read_state SET revision=revision WHERE id=1"); err != nil {
		return store.ReadState{}, err
	}
	result, err := readState(ctx, tx)
	if err != nil {
		return result, err
	}
	if request.ServerID != result.ServerID {
		return result, ErrPreferenceScope
	}
	changed := false
	for _, row := range request.Changes {
		write, err := tx.ExecContext(ctx, `INSERT INTO read_positions(chat_guid,read_through) VALUES(?,?) ON CONFLICT(chat_guid) DO UPDATE SET read_through=excluded.read_through WHERE excluded.read_through>read_positions.read_through`, row.ChatGUID, row.ReadThrough)
		if err != nil {
			return result, err
		}
		count, err := write.RowsAffected()
		if err != nil {
			return result, err
		}
		changed = changed || count > 0
	}
	if changed {
		if _, err = tx.ExecContext(ctx, "UPDATE read_state SET revision=revision+1 WHERE id=1"); err != nil {
			return result, err
		}
	}
	result, err = readState(ctx, tx)
	if err != nil {
		return result, err
	}
	return result, tx.Commit()
}

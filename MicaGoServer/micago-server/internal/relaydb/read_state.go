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
	rows, err := tx.QueryContext(ctx, "SELECT chat_guid,read_through,marked_unread,unread_revision FROM read_positions ORDER BY chat_guid")
	if err != nil {
		return result, err
	}
	defer rows.Close()
	for rows.Next() {
		var row store.ReadPosition
		var marked bool
		row.MarkedUnread = &marked
		if err = rows.Scan(&row.ChatGUID, &row.ReadThrough, &marked, &row.UnreadRevision); err != nil {
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
	current := map[string]store.ReadPosition{}
	for _, row := range result.Data {
		current[row.ChatGUID] = row
	}
	changed := false
	for _, row := range request.Changes {
		prior := current[row.ChatGUID]
		at, marked, revision := prior.ReadThrough, false, prior.UnreadRevision
		if prior.MarkedUnread != nil {
			marked = *prior.MarkedUnread
		}
		// Explicit changes are compare-and-set operations. A stale replay cannot
		// undo a newer mark or advance the watermark as part of that stale action.
		if row.MarkedUnread != nil && (row.BaseUnreadRevision == nil || *row.BaseUnreadRevision != revision) {
			continue
		}
		if row.ReadThrough > at {
			at = row.ReadThrough
			marked = false
			revision++
		}
		if row.MarkedUnread != nil && marked != *row.MarkedUnread {
			marked = *row.MarkedUnread
			revision++
		}
		oldMarked := prior.MarkedUnread != nil && *prior.MarkedUnread
		if at == prior.ReadThrough && marked == oldMarked && revision == prior.UnreadRevision {
			continue
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO read_positions(chat_guid,read_through,marked_unread,unread_revision) VALUES(?,?,?,?)
   ON CONFLICT(chat_guid) DO UPDATE SET read_through=excluded.read_through,marked_unread=excluded.marked_unread,unread_revision=excluded.unread_revision`, row.ChatGUID, at, marked, revision); err != nil {
			return result, err
		}
		changed = true
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

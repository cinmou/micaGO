package relaydb

import (
	"context"
	"database/sql"
	"strconv"
	"time"

	"micagoserver/internal/store"
)

// updateWindowLimit bounds how many lookback rows a single update pass scans.
const updateWindowLimit = 5000

type updateSource interface {
	ListMessageUpdatesPage(context.Context, int64, int64, int, store.SchemaCapabilities) ([]store.MessageUpdateRow, error)
}

// UpdatePass runs the bounded lookback update pass (v0.11.x). It detects mutable
// state changes (read/delivered/edited/unsent/send-error) on messages already
// tracked in relay.db and returns the events to broadcast. It is additive to,
// and independent of, the rowid-only new-message sync in SyncOnce.
//
// First sight of a message seeds its state WITHOUT emitting, so a fresh relay.db
// (or a brand-new message) never triggers a rebroadcast storm. Only messages
// already present in relay.messages are tracked, so system/non-renderable rows
// are ignored. A lookback of 0 disables the pass.
//
// Missing schema capabilities are skipped: the source query only selects columns
// that exist, and DiffMessageState only compares enabled fields.
func UpdatePass(ctx context.Context, source updateSource, relay *DB, caps store.SchemaCapabilities, lookback time.Duration) (UpdatePassResult, error) {
	var result UpdatePassResult
	if lookback <= 0 {
		return result, nil
	}

	after := time.Now().Add(-lookback).UnixMilli()
	value, _, err := relay.GetSyncState("update_scan_rowid")
	if err != nil {
		return result, err
	}
	var cursor int64
	if value != "" {
		cursor, err = strconv.ParseInt(value, 10, 64)
		if err != nil {
			return result, err
		}
	}
	rows, err := source.ListMessageUpdatesPage(ctx, after, cursor, updateWindowLimit, caps)
	if err != nil {
		return result, err
	}

	// v0.11.3: skip updates for blocked chats/handles (no insert/update/emit).
	snapshot, err := relay.LoadRuleSnapshot(ctx)
	if err != nil {
		return result, err
	}

	tx, err := relay.sqlDB.BeginTx(ctx, nil)
	if err != nil {
		return result, err
	}
	defer tx.Rollback()

	now := time.Now().UnixMilli()

	// Collected during the tx; MessageJSON is fetched after commit so it reflects
	// the updated row.
	type pendingUpdate struct {
		guid    string
		changed []string
	}
	var pendingUpdates []pendingUpdate

	for _, row := range rows {
		exists, err := messageExistsTx(tx, row.GUID)
		if err != nil {
			return result, err
		}
		if !exists {
			continue // not a message we track; new-message sync owns insertion
		}
		if !snapshot.SyncAllowed(row.ChatGUID, row.HandleID) {
			continue // blocked target: no further updates/emits
		}
		result.Scanned++

		current := row.State()
		old, had, err := getMessageStateTx(tx, row.GUID)
		if err != nil {
			return result, err
		}
		fingerprint := current.Fingerprint(caps)

		if !had {
			// Refresh persisted data while seeding, without a startup broadcast storm.
			if _, err := updateMessageMutableTx(tx, row); err != nil {
				return result, err
			}
			if err := upsertMessageStateTx(tx, row.GUID, current, fingerprint, now); err != nil {
				return result, err
			}
			result.Seeded++
			continue
		}
		if old.Fingerprint(caps) == fingerprint {
			// Repair rows left stale by older seed-only versions, and content
			// changes without a new state timestamp. The SQL guard avoids writes
			// for genuinely unchanged messages.
			repairFields, err := persistedMutableDiffTx(tx, row, caps)
			if err != nil {
				return result, err
			}
			affected, err := updateMessageMutableTx(tx, row)
			if err != nil {
				return result, err
			}
			if affected > 0 {
				if caps.UnsentMessages && row.DateRetracted != nil && *row.DateRetracted > 0 {
					result.Unsent = append(result.Unsent, UnsentEvent{GUID: row.GUID, ChatGUID: row.ChatGUID, DateRetracted: row.DateRetracted})
				} else if len(repairFields) > 0 {
					pendingUpdates = append(pendingUpdates, pendingUpdate{guid: row.GUID, changed: repairFields})
				}
			}
			continue
		}

		changed, retracted := store.DiffMessageState(old, current, caps)

		// Reflect the new mutable state into the relay row.
		if _, err := updateMessageMutableTx(tx, row); err != nil {
			return result, err
		}
		if err := upsertMessageStateTx(tx, row.GUID, current, fingerprint, now); err != nil {
			return result, err
		}

		if retracted {
			result.Unsent = append(result.Unsent, UnsentEvent{
				GUID:          row.GUID,
				ChatGUID:      row.ChatGUID,
				DateRetracted: row.DateRetracted,
			})
		} else if len(changed) > 0 {
			pendingUpdates = append(pendingUpdates, pendingUpdate{guid: row.GUID, changed: changed})
		}
	}

	var next int64
	if len(rows) == updateWindowLimit {
		next = rows[len(rows)-1].SourceRowID
	}
	if err := setSyncStateTx(tx, "update_scan_rowid", strconv.FormatInt(next, 10)); err != nil {
		return result, err
	}

	if err := tx.Commit(); err != nil {
		return result, err
	}

	// Build message:update payloads from the now-committed relay rows.
	for _, p := range pendingUpdates {
		messages, err := relay.GetMessagesByGUIDs(ctx, []string{p.guid})
		if err != nil {
			return result, err
		}
		if len(messages) == 0 {
			continue
		}
		result.Updates = append(result.Updates, MessageUpdate{
			Message: messages[0],
			Changed: p.changed,
		})
	}

	return result, nil
}

func messageExistsTx(tx *sql.Tx, guid string) (bool, error) {
	var one int
	err := tx.QueryRow(`SELECT 1 FROM messages WHERE guid = ? LIMIT 1`, guid).Scan(&one)
	if err == sql.ErrNoRows {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}

func getMessageStateTx(tx *sql.Tx, guid string) (store.MessageState, bool, error) {
	var (
		isRead        sql.NullInt64
		dateRead      sql.NullInt64
		isDelivered   sql.NullInt64
		dateDelivered sql.NullInt64
		dateEdited    sql.NullInt64
		dateRetracted sql.NullInt64
		errorCode     sql.NullInt64
		fingerprint   string
		updatedAt     int64
	)
	err := tx.QueryRow(`
SELECT is_read, date_read, is_delivered, date_delivered, date_edited, date_retracted, error, fingerprint, updated_at
FROM message_state WHERE guid = ?`, guid).Scan(
		&isRead, &dateRead, &isDelivered, &dateDelivered, &dateEdited, &dateRetracted, &errorCode, &fingerprint, &updatedAt,
	)
	if err == sql.ErrNoRows {
		return store.MessageState{}, false, nil
	}
	if err != nil {
		return store.MessageState{}, false, err
	}
	return store.MessageState{
		IsRead:        isRead.Valid && isRead.Int64 != 0,
		DateRead:      nullToPtr(dateRead),
		IsDelivered:   isDelivered.Valid && isDelivered.Int64 != 0,
		DateDelivered: nullToPtr(dateDelivered),
		DateEdited:    nullToPtr(dateEdited),
		DateRetracted: nullToPtr(dateRetracted),
		ErrorCode:     errorCode.Int64,
	}, true, nil
}

func upsertMessageStateTx(tx *sql.Tx, guid string, state store.MessageState, fingerprint string, now int64) error {
	_, err := tx.Exec(`
INSERT INTO message_state (
	guid, is_read, date_read, is_delivered, date_delivered, date_edited, date_retracted, error, fingerprint, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(guid) DO UPDATE SET
	is_read = excluded.is_read,
	date_read = excluded.date_read,
	is_delivered = excluded.is_delivered,
	date_delivered = excluded.date_delivered,
	date_edited = excluded.date_edited,
	date_retracted = excluded.date_retracted,
	error = excluded.error,
	fingerprint = excluded.fingerprint,
	updated_at = excluded.updated_at;
`,
		guid,
		boolToInt(state.IsRead),
		state.DateRead,
		boolToInt(state.IsDelivered),
		state.DateDelivered,
		state.DateEdited,
		state.DateRetracted,
		state.ErrorCode,
		fingerprint,
		now,
	)
	return err
}

func updateMessageMutableTx(tx *sql.Tx, row store.MessageUpdateRow) (int64, error) {
	res, err := tx.Exec(`
UPDATE messages SET
	text = ?,
	subject = ?,
	date_read = ?,
	date_delivered = ?,
	is_read = ?,
	is_delivered = ?
WHERE guid = ? AND (
 text IS NOT ? OR subject IS NOT ? OR date_read IS NOT ? OR date_delivered IS NOT ?
 OR is_read IS NOT ? OR is_delivered IS NOT ?
);
`,
		row.Text,
		row.Subject,
		row.DateRead,
		row.DateDelivered,
		boolToInt(row.IsRead),
		boolToInt(row.IsDelivered),
		row.GUID,
		row.Text, row.Subject, row.DateRead, row.DateDelivered, boolToInt(row.IsRead), boolToInt(row.IsDelivered),
	)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

func nullToPtr(v sql.NullInt64) *int64 {
	if !v.Valid {
		return nil
	}
	out := v.Int64
	return &out
}

// The persistent state fingerprint may already be current while relay.messages
// was left stale by an older release. Compare only fields supported by source.
func persistedMutableDiffTx(tx *sql.Tx, row store.MessageUpdateRow, caps store.SchemaCapabilities) ([]string, error) {
	var text, read, dateRead, delivered, dateDelivered bool
	err := tx.QueryRow(`SELECT (text IS NOT ? OR subject IS NOT ?),is_read IS NOT ?,date_read IS NOT ?,is_delivered IS NOT ?,date_delivered IS NOT ? FROM messages WHERE guid=?`, row.Text, row.Subject, boolToInt(row.IsRead), row.DateRead, boolToInt(row.IsDelivered), row.DateDelivered, row.GUID).Scan(&text, &read, &dateRead, &delivered, &dateDelivered)
	if err != nil {
		return nil, err
	}
	var fields []string
	if caps.EditedMessages && text {
		fields = append(fields, store.ChangeText)
	}
	if caps.ReadStatus && read {
		fields = append(fields, store.ChangeIsRead)
	}
	if caps.ReadStatus && dateRead {
		fields = append(fields, store.ChangeDateRead)
	}
	if caps.DeliveredStatus && delivered {
		fields = append(fields, store.ChangeIsDelivered)
	}
	if caps.DeliveredStatus && dateDelivered {
		fields = append(fields, store.ChangeDateDelivered)
	}
	return fields, nil
}

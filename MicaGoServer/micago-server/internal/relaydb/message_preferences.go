package relaydb

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"micagoserver/internal/store"
)

func (db *DB) MessagePreferences(ctx context.Context, since int64) (store.MessagePreferences, error) {
	tx, err := db.sqlDB.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return store.MessagePreferences{}, err
	}
	defer tx.Rollback()
	result, err := readMessagePreferences(ctx, tx, since)
	if err != nil {
		return result, err
	}
	return result, tx.Commit()
}

func readMessagePreferences(ctx context.Context, tx *sql.Tx, since int64) (store.MessagePreferences, error) {
	result := store.MessagePreferences{Data: []store.MessagePreference{}}
	if err := tx.QueryRowContext(ctx, "SELECT server_id, revision FROM message_preferences_state WHERE id=1").Scan(&result.ServerID, &result.Revision); err != nil {
		return result, err
	}
	rows, err := tx.QueryContext(ctx, "SELECT message_key, hidden, revision FROM message_preferences WHERE revision > ? ORDER BY revision, message_key", since)
	if err != nil {
		return result, err
	}
	defer rows.Close()
	for rows.Next() {
		var p store.MessagePreference
		if err := rows.Scan(&p.MessageKey, &p.Hidden, &p.Revision); err != nil {
			return result, err
		}
		result.Data = append(result.Data, p)
	}
	return result, rows.Err()
}

func (db *DB) MutateMessagePreferences(ctx context.Context, request store.MessagePreferenceMutation) (store.MessagePreferences, error) {
	raw, err := json.Marshal(request)
	if err != nil {
		return store.MessagePreferences{}, err
	}
	digest := fmt.Sprintf("%x", sha256.Sum256(raw))
	tx, err := db.sqlDB.BeginTx(ctx, nil)
	if err != nil {
		return store.MessagePreferences{}, err
	}
	defer tx.Rollback()
	// Acquire the SQLite writer before reading revisions.
	if _, err = tx.ExecContext(ctx, "UPDATE message_preferences_state SET revision=revision WHERE id=1"); err != nil {
		return store.MessagePreferences{}, err
	}
	result, err := readMessagePreferences(ctx, tx, 0)
	if err != nil {
		return result, err
	}
	if request.ServerID != result.ServerID {
		return result, ErrPreferenceScope
	}
	var priorHash, priorResponse string
	err = tx.QueryRowContext(ctx, "SELECT request_hash,response FROM message_preference_mutations WHERE mutation_id=?", request.MutationID).Scan(&priorHash, &priorResponse)
	if err == nil {
		if priorHash != digest {
			return result, ErrPreferenceMutation
		}
		err = json.Unmarshal([]byte(priorResponse), &result)
		return result, err
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return result, err
	}
	current := map[string]store.MessagePreference{}
	for _, p := range result.Data {
		current[p.MessageKey] = p
	}
	for _, change := range request.Changes {
		if current[change.MessageKey].Revision != change.BaseRevision {
			return result, ErrPreferenceConflict
		}
	}
	result.Revision++
	result.Data = []store.MessagePreference{}
	for _, change := range request.Changes {
		if _, err = tx.ExecContext(ctx, `INSERT INTO message_preferences(message_key,hidden,revision) VALUES(?,?,?)
   ON CONFLICT(message_key) DO UPDATE SET hidden=excluded.hidden,revision=excluded.revision`,
			change.MessageKey, change.Hidden, result.Revision); err != nil {
			return result, err
		}
		result.Data = append(result.Data, store.MessagePreference{MessageKey: change.MessageKey, Hidden: change.Hidden, Revision: result.Revision})
	}
	if _, err = tx.ExecContext(ctx, "UPDATE message_preferences_state SET revision=? WHERE id=1", result.Revision); err != nil {
		return result, err
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		return result, err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO message_preference_mutations(mutation_id,request_hash,response) VALUES(?,?,?)", request.MutationID, digest, string(encoded)); err != nil {
		return result, err
	}
	return result, tx.Commit()
}

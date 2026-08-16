package relaydb

import "fmt"

func (db *DB) Migrate() error {
	statements := []string{
		`CREATE TABLE IF NOT EXISTS chats (
			guid TEXT PRIMARY KEY,
			chat_identifier TEXT,
			service_name TEXT,
			display_name TEXT,
			is_archived INTEGER,
			updated_at INTEGER
		);`,
		`CREATE TABLE IF NOT EXISTS messages (
			guid TEXT PRIMARY KEY,
			chat_guid TEXT,
			source_rowid INTEGER,
			text TEXT,
			subject TEXT,
			service TEXT,
			account TEXT,
			date_created INTEGER,
			date_read INTEGER,
			date_delivered INTEGER,
			is_from_me INTEGER,
			is_read INTEGER,
			is_delivered INTEGER,
			handle_id TEXT,
			handle_service TEXT,
			cache_has_attachments INTEGER,
			created_at INTEGER
		);`,
		`CREATE TABLE IF NOT EXISTS sync_state (
			key TEXT PRIMARY KEY,
			value TEXT
		);`,
		`CREATE TABLE IF NOT EXISTS attachments (
			guid TEXT PRIMARY KEY,
			message_guid TEXT,
			filename TEXT,
			mime_type TEXT,
			transfer_name TEXT,
			total_bytes INTEGER,
			local_path TEXT,
			is_outgoing INTEGER,
			hide_attachment INTEGER,
			created_at INTEGER
		);`,
		`CREATE TABLE IF NOT EXISTS devices (
			id TEXT PRIMARY KEY,
			name TEXT NOT NULL,
			platform TEXT NOT NULL,
			client_type TEXT NOT NULL,
			push_provider TEXT NOT NULL,
			push_token TEXT,
			push_enabled INTEGER NOT NULL DEFAULT 0,
			last_seen_at INTEGER,
			created_at INTEGER NOT NULL,
			updated_at INTEGER NOT NULL
		);`,
		// v0.11.3: per-target sync/push rules (whitelist/blacklist overrides).
		`CREATE TABLE IF NOT EXISTS sync_rules (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			target_kind TEXT NOT NULL,
			target_value TEXT NOT NULL,
			sync_mode TEXT NOT NULL,
			push_mode TEXT NOT NULL,
			created_at INTEGER NOT NULL,
			updated_at INTEGER NOT NULL,
			UNIQUE(target_kind, target_value)
		);`,
		// v0.11.x: persisted event-state cache for the lookback update pass.
		`CREATE TABLE IF NOT EXISTS message_state (
			guid TEXT PRIMARY KEY,
			is_read INTEGER,
			date_read INTEGER,
			is_delivered INTEGER,
			date_delivered INTEGER,
			date_edited INTEGER,
			date_retracted INTEGER,
			error INTEGER,
			fingerprint TEXT NOT NULL,
			updated_at INTEGER NOT NULL
		);`,
	}

	for _, statement := range statements {
		if _, err := db.sqlDB.Exec(statement); err != nil {
			return err
		}
	}

	if err := db.ensureColumn("messages", "source_rowid", "INTEGER"); err != nil {
		return err
	}
	if err := db.ensureColumn("messages", "account", "TEXT"); err != nil {
		return err
	}
	if err := db.ensureColumn("chats", "style", "INTEGER"); err != nil {
		return err
	}
	if err := db.ensureColumn("chats", "participant_count", "INTEGER"); err != nil {
		return err
	}
	if err := db.ensureColumn("chats", "participants", "TEXT"); err != nil {
		return err
	}

	// v0.11.5: attachment fidelity — Apple UTI + sticker flag (additive).
	if err := db.ensureColumn("attachments", "uti", "TEXT"); err != nil {
		return err
	}
	if err := db.ensureColumn("attachments", "is_sticker", "INTEGER"); err != nil {
		return err
	}

	// v0.13: BlueBubbles-compatible semantic fields carried from chat.db so the
	// normal Message API can expose reactions/replies/effects/service events.
	semanticCols := []struct{ name, typ string }{
		{"has_attributed_body", "INTEGER"},
		{"associated_message_type", "INTEGER"},
		{"associated_message_guid", "TEXT"},
		{"thread_originator_guid", "TEXT"},
		{"item_type", "INTEGER"},
		{"group_action_type", "INTEGER"},
		{"group_title", "TEXT"},
		{"balloon_bundle_id", "TEXT"},
		{"expressive_send_style_id", "TEXT"},
		{"payload_data_present", "INTEGER"},
	}
	for _, c := range semanticCols {
		if err := db.ensureColumn("messages", c.name, c.typ); err != nil {
			return err
		}
	}

	// C21u: device identity carries the client app version + connection mode
	// (lan / lan_public) so the Companion can show a richer device card.
	if err := db.ensureColumn("devices", "app_version", "TEXT"); err != nil {
		return err
	}
	if err := db.ensureColumn("devices", "mode", "TEXT"); err != nil {
		return err
	}
	// C22: whether the client reports a background/push capability (FCM wake).
	if err := db.ensureColumn("devices", "background", "INTEGER"); err != nil {
		return err
	}

	// C7: persist the renderable/debug-only classification so the chat list can
	// hide noise and compute a real last-message preview without re-scanning.
	if err := db.ensureColumn("messages", "is_debug_only", "INTEGER"); err != nil {
		return err
	}
	// C12 (IMSG-derived): persist reaction rows so the chat-list preview/ordering
	// aggregate can exclude them — a tapback must not bump a chat or become its
	// preview. Reaction rows still sync so the client can merge them onto targets.
	if err := db.ensureColumn("messages", "is_reaction", "INTEGER"); err != nil {
		return err
	}

	// C33: indexes. Without these, `ListChats` runs its 7 correlated per-chat
	// subqueries as full table scans of `messages` — O(chats × messages) — which
	// times out the Companion's Sync Control load on a real (large) relay.db.
	// `idx_messages_chat_date` covers the per-chat aggregates + "latest renderable"
	// ORDER BY; the others speed up the delta cursor and attachment-preview joins.
	// Created after the additive columns above so composite indexes can include
	// them. All IF NOT EXISTS — idempotent on every start.
	indexes := []string{
		`CREATE INDEX IF NOT EXISTS idx_messages_chat_date ON messages(chat_guid, date_created)`,
		`CREATE INDEX IF NOT EXISTS idx_messages_chat_date_row ON messages(chat_guid, date_created DESC, source_rowid DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_messages_source_rowid ON messages(source_rowid)`,
		`CREATE INDEX IF NOT EXISTS idx_messages_date_created ON messages(date_created)`,
		`CREATE INDEX IF NOT EXISTS idx_attachments_message_guid ON attachments(message_guid)`,
	}
	for _, statement := range indexes {
		if _, err := db.sqlDB.Exec(statement); err != nil {
			return err
		}
	}

	return nil
}

func (db *DB) ensureColumn(table, column, columnType string) error {
	rows, err := db.sqlDB.Query(fmt.Sprintf("PRAGMA table_info(%s);", table))
	if err != nil {
		return err
	}
	defer rows.Close()

	for rows.Next() {
		var cid int
		var name, typ string
		var notNull, pk int
		var dflt any
		if err := rows.Scan(&cid, &name, &typ, &notNull, &dflt, &pk); err != nil {
			return err
		}
		if name == column {
			return nil
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}

	_, err = db.sqlDB.Exec(fmt.Sprintf("ALTER TABLE %s ADD COLUMN %s %s;", table, column, columnType))
	return err
}

package relaydb

// Keep new cursors distinct from legacy source ROWIDs and exactly representable
// by JSON consumers. Legacy cursors replay current records once after upgrade.
const messageCursorBase int64 = 1 << 52

func (db *DB) migrateMessageChanges() error {
	tx, err := db.sqlDB.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	statements := []string{
		`CREATE TABLE IF NOT EXISTS message_changes (seq INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT NOT NULL UNIQUE)`,
		`INSERT OR IGNORE INTO message_changes(guid) SELECT guid FROM messages WHERE NOT EXISTS (SELECT 1 FROM message_changes WHERE message_changes.guid = messages.guid) ORDER BY source_rowid`,
	}
	statements = append(statements, `CREATE TRIGGER IF NOT EXISTS delta_messages_insert AFTER INSERT ON messages BEGIN DELETE FROM message_changes WHERE guid = NEW.guid; INSERT INTO message_changes(guid) SELECT NEW.guid WHERE EXISTS (SELECT 1 FROM messages WHERE guid = NEW.guid); END`)
	statements = append(statements, `CREATE TRIGGER IF NOT EXISTS delta_messages_update AFTER UPDATE ON messages BEGIN DELETE FROM message_changes WHERE guid = NEW.guid; INSERT INTO message_changes(guid) SELECT NEW.guid WHERE EXISTS (SELECT 1 FROM messages WHERE guid = NEW.guid); END`)
	statements = append(statements, `CREATE TRIGGER IF NOT EXISTS delta_messages_delete AFTER DELETE ON messages BEGIN DELETE FROM message_changes WHERE guid = OLD.guid; END`)
	statements = append(statements, `CREATE TRIGGER IF NOT EXISTS delta_message_state_insert AFTER INSERT ON message_state BEGIN DELETE FROM message_changes WHERE guid = NEW.guid; INSERT INTO message_changes(guid) SELECT NEW.guid WHERE EXISTS (SELECT 1 FROM messages WHERE guid = NEW.guid); END`)
	statements = append(statements, `CREATE TRIGGER IF NOT EXISTS delta_message_state_update AFTER UPDATE ON message_state WHEN OLD.fingerprint IS NOT NEW.fingerprint BEGIN DELETE FROM message_changes WHERE guid = NEW.guid; INSERT INTO message_changes(guid) SELECT NEW.guid WHERE EXISTS (SELECT 1 FROM messages WHERE guid = NEW.guid); END`)
	statements = append(statements, `CREATE TRIGGER IF NOT EXISTS delta_message_state_delete AFTER DELETE ON message_state BEGIN DELETE FROM message_changes WHERE guid = OLD.guid; INSERT INTO message_changes(guid) SELECT OLD.guid WHERE EXISTS (SELECT 1 FROM messages WHERE guid = OLD.guid); END`)
	statements = append(statements, `CREATE TRIGGER IF NOT EXISTS delta_attachments_insert AFTER INSERT ON attachments BEGIN DELETE FROM message_changes WHERE guid = NEW.message_guid; INSERT INTO message_changes(guid) SELECT NEW.message_guid WHERE EXISTS (SELECT 1 FROM messages WHERE guid = NEW.message_guid); END`)
	statements = append(statements, `CREATE TRIGGER IF NOT EXISTS delta_attachments_update AFTER UPDATE ON attachments WHEN OLD.filename IS NOT NEW.filename OR OLD.mime_type IS NOT NEW.mime_type OR OLD.transfer_name IS NOT NEW.transfer_name OR OLD.total_bytes IS NOT NEW.total_bytes OR OLD.local_path IS NOT NEW.local_path OR OLD.is_outgoing IS NOT NEW.is_outgoing OR OLD.hide_attachment IS NOT NEW.hide_attachment OR OLD.uti IS NOT NEW.uti OR OLD.is_sticker IS NOT NEW.is_sticker BEGIN DELETE FROM message_changes WHERE guid = NEW.message_guid; INSERT INTO message_changes(guid) SELECT NEW.message_guid WHERE EXISTS (SELECT 1 FROM messages WHERE guid = NEW.message_guid); END`)
	statements = append(statements, `CREATE TRIGGER IF NOT EXISTS delta_attachments_delete AFTER DELETE ON attachments BEGIN DELETE FROM message_changes WHERE guid = OLD.message_guid; INSERT INTO message_changes(guid) SELECT OLD.message_guid WHERE EXISTS (SELECT 1 FROM messages WHERE guid = OLD.message_guid); END`)
	for _, statement := range statements {
		if _, err := tx.Exec(statement); err != nil {
			return err
		}
	}
	return tx.Commit()
}

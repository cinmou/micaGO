package relaydb

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"

	_ "github.com/mattn/go-sqlite3"
)

type DB struct {
	sqlDB *sql.DB
	path  string
}

func Open(path string) (*DB, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}

	// relay.db includes authoritative privacy/preferences and device state.
	// Corruption must not silently replace it with an empty server identity.
	return openOnce(path)
}

func openOnce(path string) (*DB, error) {
	// SQLite otherwise creates a 0644 database under a typical umask. Protect
	// message content and device push credentials even in a custom directory.
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err = file.Chmod(0o600); err != nil {
		_ = file.Close()
		return nil, err
	}
	if err = file.Close(); err != nil {
		return nil, err
	}
	for _, suffix := range []string{"-wal", "-shm", "-journal"} {
		if err = os.Chmod(path+suffix, 0o600); err != nil && !os.IsNotExist(err) {
			return nil, err
		}
	}

	sqlDB, err := sql.Open("sqlite3", fmt.Sprintf("file:%s?_busy_timeout=5000", path))
	if err != nil {
		return nil, err
	}

	if err := sqlDB.Ping(); err != nil {
		_ = sqlDB.Close()
		return nil, err
	}

	db := &DB{sqlDB: sqlDB, path: path}
	if err := db.Migrate(); err != nil {
		_ = db.Close()
		return nil, err
	}

	return db, nil
}

func (db *DB) Close() error {
	return db.sqlDB.Close()
}

func (db *DB) SetSyncState(key, value string) error {
	_, err := db.sqlDB.Exec(`
INSERT INTO sync_state (key, value)
VALUES (?, ?)
ON CONFLICT(key) DO UPDATE SET value = excluded.value;
`, key, value)
	return err
}

func (db *DB) GetSyncState(key string) (string, bool, error) {
	var value string
	err := db.sqlDB.QueryRow(`SELECT value FROM sync_state WHERE key = ?`, key).Scan(&value)
	if err == sql.ErrNoRows {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return value, true, nil
}

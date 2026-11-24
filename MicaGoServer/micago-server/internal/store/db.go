package store

import (
	"database/sql"
	"fmt"
	"strings"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

// readOnlyDSN builds the chat.db connection string. It mirrors the IMSG
// reference (Ref/imsg MessageStore.init): open read-only and WAL-aware with a
// busy timeout, and crucially WITHOUT immutable=1.
//
// immutable=1 tells SQLite the file can never change, so it skips locking AND
// ignores the -wal file, reading raw pages straight from the main file. While
// Messages.app is mid-write/mid-checkpoint that yields torn pages and the error
// "database disk image is malformed". Plain mode=ro is WAL-aware: SQLite reads
// the -wal/-shm and returns a consistent committed snapshot, waiting out a busy
// writer for up to _busy_timeout. See docs/c15-imsg-db-open-and-error-handling.md.
func readOnlyDSN(path string) string {
	return fmt.Sprintf("file:%s?mode=ro&_busy_timeout=5000&_cache_size=-512", path)
}

// ChatDBOpenOptions returns the SQLite URI options used to open chat.db (the
// part after "?"), surfaced in /api/server/status so a stale binary that still
// uses immutable=1 is externally detectable (C17).
func ChatDBOpenOptions() string {
	dsn := readOnlyDSN("")
	if i := strings.Index(dsn, "?"); i >= 0 {
		return dsn[i+1:]
	}
	return ""
}

func OpenReadOnly(path string) (*sql.DB, error) {
	db, err := sql.Open("sqlite3", readOnlyDSN(path))
	if err != nil {
		return nil, err
	}

	if err := db.Ping(); err != nil {
		_ = db.Close()
		return nil, err
	}

	db.SetMaxOpenConns(2)
	db.SetMaxIdleConns(1)
	db.SetConnMaxIdleTime(2 * time.Minute)

	return db, nil
}

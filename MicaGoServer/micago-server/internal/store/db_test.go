package store

import (
	"context"
	"database/sql"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

// C15: the chat.db connection must mirror IMSG — read-only + busy timeout, and
// crucially WITHOUT immutable=1. immutable=1 makes SQLite ignore the -wal file
// and read torn pages while Messages.app writes → "database disk image is
// malformed". This guards against the flag being reintroduced.
func TestReadOnlyDSNMatchesIMSGFlags(t *testing.T) {
	dsn := readOnlyDSN("/tmp/chat.db")
	if !strings.Contains(dsn, "mode=ro") {
		t.Fatalf("dsn must be read-only, got %q", dsn)
	}
	if !strings.Contains(dsn, "_busy_timeout=5000") {
		t.Fatalf("dsn must set a busy timeout, got %q", dsn)
	}
	if strings.Contains(dsn, "immutable") {
		t.Fatalf("dsn must NOT set immutable (it breaks WAL reads), got %q", dsn)
	}
}

// OpenReadOnly must successfully read a WAL-mode database — the mode Apple's
// chat.db actually uses. Under immutable=1 this could read a stale/torn view;
// under plain mode=ro it reads the committed snapshot including the WAL.
func TestOpenReadOnlyReadsWALDatabase(t *testing.T) {
	path := filepath.Join(t.TempDir(), "chat.db")

	// Create a WAL-mode DB with a committed row using a normal RW connection.
	rw, err := sql.Open("sqlite3", fmt.Sprintf("file:%s?_busy_timeout=5000", path))
	if err != nil {
		t.Fatalf("open rw: %v", err)
	}
	if _, err := rw.Exec("PRAGMA journal_mode=WAL;"); err != nil {
		t.Fatalf("set wal: %v", err)
	}
	if _, err := rw.Exec("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);"); err != nil {
		t.Fatalf("create: %v", err)
	}
	if _, err := rw.Exec("INSERT INTO t (id, v) VALUES (1, 'hello');"); err != nil {
		t.Fatalf("insert: %v", err)
	}

	// Read it back read-only while the writer connection is still open (mirrors
	// Messages.app holding chat.db open).
	ro, err := OpenReadOnly(path)
	if err != nil {
		t.Fatalf("OpenReadOnly: %v", err)
	}
	defer ro.Close()

	var v string
	if err := ro.QueryRowContext(context.Background(), "SELECT v FROM t WHERE id = 1").Scan(&v); err != nil {
		t.Fatalf("read row: %v", err)
	}
	if v != "hello" {
		t.Fatalf("got %q, want hello", v)
	}

	// The read-only connection must not be able to write to Apple's DB.
	if _, err := ro.Exec("INSERT INTO t (id, v) VALUES (2, 'nope');"); err == nil {
		t.Fatal("read-only connection unexpectedly allowed a write")
	}

	_ = rw.Close()
}

func TestOpenReadOnlyPoolAndCacheSize(t *testing.T) {
	path := filepath.Join(t.TempDir(), "chat.db")
	rw, err := sql.Open("sqlite3", fmt.Sprintf("file:%s?_busy_timeout=5000", path))
	if err != nil {
		t.Fatalf("open rw: %v", err)
	}
	if _, err := rw.Exec("CREATE TABLE t (id INTEGER PRIMARY KEY);"); err != nil {
		_ = rw.Close()
		t.Fatalf("create: %v", err)
	}
	_ = rw.Close()

	ro, err := OpenReadOnly(path)
	if err != nil {
		t.Fatalf("OpenReadOnly: %v", err)
	}
	defer ro.Close()

	if got := ro.Stats().MaxOpenConnections; got != 2 {
		t.Fatalf("expected MaxOpenConnections=2, got %d", got)
	}
	var cacheSize int
	if err := ro.QueryRowContext(context.Background(), "PRAGMA cache_size;").Scan(&cacheSize); err != nil {
		t.Fatalf("query PRAGMA cache_size: %v", err)
	}
	if cacheSize != -512 {
		t.Fatalf("expected PRAGMA cache_size=-512, got %d", cacheSize)
	}
}

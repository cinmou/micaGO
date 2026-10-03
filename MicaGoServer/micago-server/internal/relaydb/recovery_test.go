package relaydb

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestCorruptRelayIsNeverSilentlyReset(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "relay.db")
	original := []byte("damaged sqlite database containing authoritative micaGO state")
	if err := os.WriteFile(path, original, 0600); err != nil {
		t.Fatal(err)
	}
	for attempt := 0; attempt < 2; attempt++ {
		db, err := Open(path)
		if db != nil {
			db.Close()
			t.Fatal("corruption returned a replacement database")
		}
		if err == nil {
			t.Fatal("corruption was hidden")
		}
		actual, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(actual, original) {
			t.Fatal("original damaged database was modified")
		}
		files, err := os.ReadDir(dir)
		if err != nil {
			t.Fatal(err)
		}
		if len(files) != 1 || files[0].Name() != "relay.db" {
			t.Fatal("corruption renamed or rebuilt state")
		}
	}
}

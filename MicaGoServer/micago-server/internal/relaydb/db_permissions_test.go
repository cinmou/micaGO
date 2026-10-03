package relaydb

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestRelayDatabaseIsPrivateAcrossCreateAndReopen(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("POSIX file modes")
	}
	dir := filepath.Join(t.TempDir(), "new-cache")
	path := filepath.Join(dir, "relay.db")
	db, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	db.Close()
	for _, target := range []struct {
		path string
		mode os.FileMode
	}{{dir, 0700}, {path, 0600}} {
		info, err := os.Stat(target.path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != target.mode {
			t.Fatalf("mode=%o want=%o", info.Mode().Perm(), target.mode)
		}
	}
	if err := os.Chmod(path, 0644); err != nil {
		t.Fatal(err)
	}
	db, err = Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatal("old readable database was not secured")
	}
}

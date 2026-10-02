package security

import (
	"crypto/tls"
	"os"
	"path/filepath"
	"testing"
)

func TestPersistedTLSIdentity(t *testing.T) {
	dir := t.TempDir()
	config, pin, err := ServerTLS(dir)
	if err != nil {
		t.Fatal(err)
	}
	if config.MinVersion < tls.VersionTLS12 || len(pin) != 64 {
		t.Fatal("invalid TLS configuration")
	}
	_, again, err := ServerTLS(dir)
	if err != nil || pin != again {
		t.Fatal("TLS identity changed")
	}
	info, err := os.Stat(filepath.Join(dir, "server.key"))
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("private key permissions")
	}
	if err = os.Remove(filepath.Join(dir, "server.key")); err != nil {
		t.Fatal(err)
	}
	if _, _, err = ServerTLS(dir); err == nil {
		t.Fatal("partial identity silently replaced")
	}
}

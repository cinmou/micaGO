package app

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"micagoserver/internal/config"
)

func TestStartupCreatesConfigBeforeMessagesAccess(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	// A new home has no Messages database. Configuration must still be ready
	// for the Companion to read, even when Full Disk Access/setup is pending.
	if err := Run(Options{}); err == nil || !strings.Contains(err.Error(), "open chat.db") {
		t.Fatalf("expected startup to reach the Messages database, got %v", err)
	}
	cfg, err := config.Load(config.Options{})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.FirstRun || len(cfg.AuthToken) != 64 || cfg.NotificationPreview != "sender_and_text" {
		t.Fatal("backend did not persist its canonical configuration defaults")
	}
	info, err := os.Stat(filepath.Join(home, ".micago", "config.yaml"))
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatal("configuration must be private to the current user")
	}
}

func TestStartupLeavesInvalidConfigUntouched(t *testing.T) {
	for _, body := range []string{"auth: [invalid YAML", "auth:\n  security_version: 84\n  token: \"\"\n"} {
		t.Run(body[:4], func(t *testing.T) {
			home := t.TempDir()
			t.Setenv("HOME", home)
			dir := filepath.Join(home, ".micago")
			if err := os.Mkdir(dir, 0o700); err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(dir, "config.yaml")
			if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := Run(Options{}); err == nil || strings.Contains(err.Error(), "open chat.db") {
				t.Fatal("invalid configuration should fail before Messages access")
			}
			actual, err := os.ReadFile(path)
			if err != nil || string(actual) != body {
				t.Fatal("invalid existing configuration was replaced")
			}
		})
	}
}

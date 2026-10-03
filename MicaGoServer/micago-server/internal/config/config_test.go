package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadGeneratesConfigAndToken(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	cfg, err := Load(Options{})
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.FirstRun {
		t.Fatal("expected first run config generation")
	}
	if len(cfg.AuthToken) < 64 {
		t.Fatalf("expected generated token, got %q", cfg.AuthToken)
	}
	if cfg.HTTPAddr != "0.0.0.0:3000" {
		t.Fatalf("fresh config HTTPAddr = %q, want LAN-capable default", cfg.HTTPAddr)
	}

	body, err := os.ReadFile(filepath.Join(home, ".micago", "config.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), "token:") {
		t.Fatalf("expected token in config file, got %s", string(body))
	}
	if !strings.Contains(string(body), `addr: "0.0.0.0:3000"`) {
		t.Fatalf("expected LAN-capable addr in config file, got %s", string(body))
	}
}

// A saved Public URL must survive a restart (write to config, reload), and
// clearing it must remove it — no other fields lost in the round-trip.
func TestPublicURLSurvivesRestart(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	path := filepath.Join(home, ".micago", "config.yaml")

	// First run generates the config.
	if _, err := Load(Options{}); err != nil {
		t.Fatal(err)
	}

	// Save a public URL (what POST /api/server/public-url does on the server).
	if err := UpdatePublicBaseURL(path, "https://micago.example.com", true, "auto"); err != nil {
		t.Fatal(err)
	}

	// Restart: reload from disk. The saved Public URL must be preserved.
	cfg, err := Load(Options{})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.PublicBaseURL != "https://micago.example.com" {
		t.Fatalf("public URL not preserved across restart: %q", cfg.PublicBaseURL)
	}
	// The bind/token must still be intact (round-trip didn't drop fields).
	if cfg.HTTPAddr != "0.0.0.0:3000" || len(cfg.AuthToken) < 64 {
		t.Fatalf("round-trip lost fields: addr=%q tokenLen=%d", cfg.HTTPAddr, len(cfg.AuthToken))
	}

	// Removing the public URL clears it (no stale public candidate).
	if err := UpdatePublicBaseURL(path, "", true, "auto"); err != nil {
		t.Fatal(err)
	}
	cfg, err = Load(Options{})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.PublicBaseURL != "" {
		t.Fatalf("public URL not cleared: %q", cfg.PublicBaseURL)
	}
}

// A pre-C25 config bound loopback-only must migrate to the LAN-capable default
// on load (and persist), so LAN endpoints can be derived and Android can pair.
func TestLoopbackBindMigratesToLAN(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	path := filepath.Join(home, ".micago", "config.yaml")

	// First run generates the config, then simulate an old loopback bind on disk.
	if _, err := Load(Options{}); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	stale := strings.Replace(string(body), `addr: "0.0.0.0:3000"`, `addr: "127.0.0.1:3000"`, 1)
	if stale == string(body) {
		t.Fatal("test setup did not rewrite addr")
	}
	if err := os.WriteFile(path, []byte(stale), 0o600); err != nil {
		t.Fatal(err)
	}

	cfg, err := Load(Options{})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.HTTPAddr != "0.0.0.0:3000" {
		t.Fatalf("loopback bind not migrated: HTTPAddr=%q", cfg.HTTPAddr)
	}
	// The migration must persist so a later load (and the running server) agree.
	persisted, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(persisted), `addr: "0.0.0.0:3000"`) {
		t.Fatalf("migration not persisted: %s", string(persisted))
	}

	// An explicit --addr override (incl. a deliberate local bind) is respected.
	cfg, err = Load(Options{Addr: "127.0.0.1:3000", DisableAuth: true})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.HTTPAddr != "127.0.0.1:3000" {
		t.Fatalf("explicit --addr override was migrated away: %q", cfg.HTTPAddr)
	}
}

func TestParseConfigMissingAddrUsesLANDefault(t *testing.T) {
	cfg, err := parseConfig(`auth:
  token: "abc"
`)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Server.Addr != "0.0.0.0:3000" {
		t.Fatalf("missing addr default = %q, want LAN-capable default", cfg.Server.Addr)
	}
}

func TestValidateSecurityRejectsDisableAuthOnNonLocalAddress(t *testing.T) {
	err := ValidateSecurity(Config{
		HTTPAddr:     "0.0.0.0:3000",
		AuthDisabled: true,
	})
	if err == nil {
		t.Fatal("expected disable-auth validation error")
	}
}

func TestPublicBaseURLRejectsEmbeddedCredentials(t *testing.T) {
	for _, target := range []string{"https://user:pass@example.com", "https://user@example.com", "http://:3000"} {
		if ValidatePublicBaseURL(target) == nil {
			t.Fatal("accepted credentials or empty hostname")
		}
	}
	if err := ValidatePublicBaseURL("https://example.com:3000"); err != nil {
		t.Fatal(err)
	}
}

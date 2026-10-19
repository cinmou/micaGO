package imessage

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// After an install, invalidating the capability cache must make the very next
// probe report the helper as ready — without waiting for the TTL. This is the
// core of the "installed but still shows unavailable" fix.
func TestCapabilitiesRescanAfterInstall(t *testing.T) {
	withMacOSVersion(t, "14.0")
	installed := false
	p := &HelperPerformer{
		CacheTTL: 30 * time.Second,
		Lookup: func() (string, error) {
			if !installed {
				return "", errors.New("MicaGo IMCore helper is not installed")
			}
			return "/tmp/micago-imcore-helper", nil
		},
		Runner: func(_ context.Context, _ string, _ helperEnvelope) (helperEnvelope, error) {
			return helperEnvelope{Capabilities: map[string]bool{"edit": true, "retract": true, "delete": true}}, nil
		},
	}

	// 1) Nothing installed → missing.
	if c := p.Capabilities(context.Background()); c.Available || c.State != HelperStateMissing {
		t.Fatalf("pre-install: got available=%v state=%q, want missing", c.Available, c.State)
	}

	// 2) Install, but the cache still holds the "missing" result.
	installed = true
	if c := p.Capabilities(context.Background()); c.Available {
		t.Fatal("cache should still report missing until invalidated")
	}

	// 3) Invalidate → next probe re-scans → ready.
	p.InvalidateCapabilities()
	c := p.Capabilities(context.Background())
	if !c.Available || c.State != HelperStateReady || !c.Edit || !c.Retract || !c.Delete {
		t.Fatalf("post-rescan: got %+v, want ready+all selectors", c)
	}
}

// A helper that runs but reports no usable selectors is "unsupported", not ready.
func TestCapabilitiesUnsupportedSelectors(t *testing.T) {
	withMacOSVersion(t, "14.0")
	p := &HelperPerformer{
		Lookup: func() (string, error) { return "/tmp/h", nil },
		Runner: func(_ context.Context, _ string, _ helperEnvelope) (helperEnvelope, error) {
			return helperEnvelope{Capabilities: map[string]bool{}}, nil
		},
	}
	c := p.Capabilities(context.Background())
	if c.Available || c.State != HelperStateUnsupported {
		t.Fatalf("got available=%v state=%q, want unsupported", c.Available, c.State)
	}
}

// A helper installed into ~/.micago/bin (the Companion's install target) must be
// discovered by the backend without re-bundling — closing the install loop.
func TestHelperPathFindsInstalledBinary(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("MICAGO_IMCORE_HELPER", "") // ensure the env override doesn't win

	// No helper anywhere yet → not installed.
	p := &HelperPerformer{}
	if _, err := p.helperPath(); err == nil {
		t.Fatal("expected no helper before install")
	}

	// Install an executable stub into ~/.micago/bin.
	dir := filepath.Join(home, ".micago", "bin")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	bin := filepath.Join(dir, "micago-imcore-helper")
	if err := os.WriteFile(bin, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	got, err := p.helperPath()
	if err != nil {
		t.Fatalf("expected to find installed helper, got error: %v", err)
	}
	if got != bin {
		t.Fatalf("helperPath = %q, want %q", got, bin)
	}
}

func TestCapabilitiesRejectsPreVenturaBeforeHelperInstall(t *testing.T) {
	withMacOSVersion(t, "12.7")
	p := &HelperPerformer{
		Lookup: func() (string, error) {
			t.Fatal("helper lookup should not run on unsupported macOS")
			return "", nil
		},
	}
	c := p.Capabilities(context.Background())
	if c.Available || c.PlatformSupported || c.State != HelperStateUnsupported {
		t.Fatalf("got %+v, want unsupported platform", c)
	}
	if c.MinimumMacOS != "13.0" || c.Reason == "" {
		t.Fatalf("missing support metadata: %+v", c)
	}
}

func TestCapabilitiesWarnsForTahoe(t *testing.T) {
	withMacOSVersion(t, "26.0")
	p := &HelperPerformer{
		Lookup: func() (string, error) { return "/tmp/h", nil },
		Runner: func(_ context.Context, _ string, _ helperEnvelope) (helperEnvelope, error) {
			return helperEnvelope{Capabilities: map[string]bool{"edit": true}}, nil
		},
	}
	c := p.Capabilities(context.Background())
	if !c.Available || c.PlatformWarning == "" {
		t.Fatalf("got %+v, want ready with Tahoe warning", c)
	}
}

func withMacOSVersion(t *testing.T, version string) {
	t.Helper()
	old := detectMacOSProductVersion
	oldGOOS := currentGOOS
	detectMacOSProductVersion = func() string { return version }
	currentGOOS = "darwin"
	t.Cleanup(func() {
		detectMacOSProductVersion = old
		currentGOOS = oldGOOS
	})
}

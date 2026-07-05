package notify

import "testing"

func TestContactCacheResolvesPhonesAndEmails(t *testing.T) {
	cache := newContactCache()
	cache.Set([]ContactEntry{{
		Name:      "Alice",
		Addresses: []string{"+1 (555) 000-1234", "ALICE@EXAMPLE.COM"},
	}})

	if got := cache.Resolve("+15550001234"); got != "Alice" {
		t.Fatalf("expected exact phone match, got %q", got)
	}
	if got := cache.Resolve("5550001234"); got != "Alice" {
		t.Fatalf("expected last-10 phone fallback, got %q", got)
	}
	if got := cache.Resolve("alice@example.com"); got != "Alice" {
		t.Fatalf("expected case-insensitive email match, got %q", got)
	}
}

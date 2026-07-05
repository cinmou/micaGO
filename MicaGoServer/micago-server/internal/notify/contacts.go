package notify

import (
	"strings"
	"sync"
)

// ContactEntry is a local-only name/address row sent by the Mac companion.
// It intentionally contains only display names plus phone/email handles.
type ContactEntry struct {
	Name      string   `json:"name"`
	Addresses []string `json:"addresses"`
}

type contactCache struct {
	mu       sync.RWMutex
	byHandle map[string]string
	byLast10 map[string]string
}

func newContactCache() *contactCache {
	return &contactCache{
		byHandle: map[string]string{},
		byLast10: map[string]string{},
	}
}

func (c *contactCache) Set(entries []ContactEntry) {
	nextHandle := make(map[string]string)
	nextLast10 := make(map[string]string)
	for _, entry := range entries {
		name := strings.TrimSpace(entry.Name)
		if name == "" {
			continue
		}
		for _, raw := range entry.Addresses {
			normalized := normalizeContactHandle(raw)
			if normalized == "" {
				continue
			}
			nextHandle[normalized] = name
			digits := digitsOnly(raw)
			if len(digits) >= 10 {
				nextLast10[digits[len(digits)-10:]] = name
			}
		}
	}
	c.mu.Lock()
	c.byHandle = nextHandle
	c.byLast10 = nextLast10
	c.mu.Unlock()
}

func (c *contactCache) Resolve(raw string) string {
	normalized := normalizeContactHandle(raw)
	if normalized == "" {
		return ""
	}
	c.mu.RLock()
	defer c.mu.RUnlock()
	if name := c.byHandle[normalized]; name != "" {
		return name
	}
	digits := digitsOnly(raw)
	if len(digits) >= 10 {
		return c.byLast10[digits[len(digits)-10:]]
	}
	return ""
}

func normalizeContactHandle(raw string) string {
	s := strings.TrimSpace(raw)
	if s == "" {
		return ""
	}
	if strings.Contains(s, "@") {
		return strings.ToLower(s)
	}
	var out strings.Builder
	for i, r := range s {
		switch {
		case r >= '0' && r <= '9':
			out.WriteRune(r)
		case r == '+' && i == 0:
			out.WriteRune(r)
		}
	}
	if out.Len() > 0 {
		return out.String()
	}
	return strings.ToLower(s)
}

func digitsOnly(raw string) string {
	var out strings.Builder
	for _, r := range raw {
		if r >= '0' && r <= '9' {
			out.WriteRune(r)
		}
	}
	return out.String()
}

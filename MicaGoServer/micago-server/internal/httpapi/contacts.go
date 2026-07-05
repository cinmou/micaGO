package httpapi

import (
	"encoding/json"
	"net/http"
	"strings"

	"micagoserver/internal/notify"
)

const (
	maxContactEntries   = 10000
	maxContactAddresses = 50000
)

type contactCacheRequest struct {
	Contacts []notify.ContactEntry `json:"contacts"`
}

func (h *Handlers) PutContactCache(w http.ResponseWriter, r *http.Request) {
	if h.contactCache == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "contact_cache_unavailable", "contact cache is not available")
		return
	}
	var req contactCacheRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<20)).Decode(&req); err != nil {
		writeBadRequest(w, "invalid contact cache payload")
		return
	}
	entries, addressCount := sanitizeContactEntries(req.Contacts)
	h.contactCache.SetContactCache(entries)
	writeJSON(w, http.StatusOK, map[string]any{
		"data": map[string]any{
			"contacts":  len(entries),
			"addresses": addressCount,
		},
	})
}

func sanitizeContactEntries(in []notify.ContactEntry) ([]notify.ContactEntry, int) {
	out := make([]notify.ContactEntry, 0, min(len(in), maxContactEntries))
	addressCount := 0
	for _, entry := range in {
		if len(out) >= maxContactEntries || addressCount >= maxContactAddresses {
			break
		}
		name := strings.TrimSpace(entry.Name)
		if name == "" {
			continue
		}
		addresses := make([]string, 0, len(entry.Addresses))
		for _, raw := range entry.Addresses {
			if addressCount >= maxContactAddresses {
				break
			}
			addr := strings.TrimSpace(raw)
			if addr == "" {
				continue
			}
			addresses = append(addresses, addr)
			addressCount++
		}
		if len(addresses) == 0 {
			continue
		}
		out = append(out, notify.ContactEntry{Name: name, Addresses: addresses})
	}
	return out, addressCount
}

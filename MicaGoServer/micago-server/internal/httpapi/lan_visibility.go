package httpapi

import (
	"context"
	"encoding/json"
	"io"
	"micagoserver/internal/config"
	"micagoserver/internal/realtime"
	"net/http"
	"sort"
	"strings"
)

type lanVisibilityService interface {
	HiddenLANEndpoints(context.Context) ([]string, error)
	SetHiddenLANEndpoints(context.Context, []string) error
}

func (h *Handlers) SetLANVisibility(service lanVisibilityService, events eventBroadcaster) {
	h.lanVisibility = service
	h.lanVisibilityEvents = events
}
func (h *Handlers) PutLANVisibility(w http.ResponseWriter, r *http.Request) {
	if h.lanVisibility == nil {
		writeInternalError(w)
		return
	}
	var request struct {
		HiddenURLs []string `json:"hiddenBaseUrls"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		writeBadRequest(w, "invalid LAN visibility")
		return
	}
	if err := decoder.Decode(new(any)); err != io.EOF || request.HiddenURLs == nil || len(request.HiddenURLs) > 200 {
		writeBadRequest(w, "invalid LAN visibility")
		return
	}
	seen := map[string]bool{}
	hidden := []string{}
	for _, raw := range request.HiddenURLs {
		value := strings.TrimRight(strings.TrimSpace(raw), "/")
		if len(value) > 2048 || config.ValidatePublicBaseURL(value) != nil {
			writeBadRequest(w, "invalid LAN endpoint")
			return
		}
		if !seen[value] {
			seen[value] = true
			hidden = append(hidden, value)
		}
	}
	sort.Strings(hidden)
	before := h.buildServerURLs().ConnectionRevision
	if err := h.lanVisibility.SetHiddenLANEndpoints(r.Context(), hidden); err != nil {
		h.logInternal("LAN visibility", err)
		writeInternalError(w)
		return
	}
	result := h.buildServerURLs()
	if result.ConnectionRevision != before && h.lanVisibilityEvents != nil {
		_ = h.lanVisibilityEvents.Broadcast(r.Context(), realtime.Event{Type: "connection:updated", Data: map[string]any{"connectionRevision": result.ConnectionRevision}})
	}
	writeJSON(w, http.StatusOK, result)
}

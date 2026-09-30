package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"micagoserver/internal/realtime"
	"micagoserver/internal/relaydb"
	"micagoserver/internal/store"
	"net/http"
	"strconv"
	"strings"
)

type messagePreferenceService interface {
	MessagePreferences(context.Context, int64) (store.MessagePreferences, error)
	MutateMessagePreferences(context.Context, store.MessagePreferenceMutation) (store.MessagePreferences, error)
}

func (h *Handlers) SetMessagePreferences(service messagePreferenceService, events eventBroadcaster) {
	h.messagePreferences = service
	h.messagePreferenceEvents = events
}

func (h *Handlers) GetMessagePreferences(w http.ResponseWriter, r *http.Request) {
	if h.messagePreferences == nil {
		writeInternalError(w)
		return
	}
	since := int64(0)
	if raw := r.URL.Query().Get("since"); raw != "" {
		var err error
		since, err = strconv.ParseInt(raw, 10, 64)
		if err != nil || since < 0 {
			writeBadRequest(w, "invalid preference cursor")
			return
		}
	}
	result, err := h.messagePreferences.MessagePreferences(r.Context(), since)
	if err != nil {
		h.logInternal("chat preferences", err)
		writeInternalError(w)
		return
	}
	if since > result.Revision {
		writeJSON(w, http.StatusConflict, map[string]any{"code": "preference_cursor_reset", "serverId": result.ServerID})
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (h *Handlers) PatchMessagePreferences(w http.ResponseWriter, r *http.Request) {
	if h.messagePreferences == nil {
		writeInternalError(w)
		return
	}
	var wire struct {
		ServerID   string `json:"serverId"`
		MutationID string `json:"mutationId"`
		Changes    []struct {
			MessageKey   string `json:"messageKey"`
			Hidden       *bool  `json:"hidden"`
			BaseRevision *int64 `json:"baseRevision"`
		} `json:"changes"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 256*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&wire); err != nil {
		writeBadRequest(w, "invalid preference mutation")
		return
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		writeBadRequest(w, "invalid preference mutation")
		return
	}
	request := store.MessagePreferenceMutation{ServerID: wire.ServerID, MutationID: wire.MutationID}
	for _, change := range wire.Changes {
		if change.Hidden == nil || change.BaseRevision == nil {
			writeBadRequest(w, "hidden and baseRevision are required")
			return
		}
		request.Changes = append(request.Changes, store.MessagePreferenceChange{MessageKey: change.MessageKey, Hidden: *change.Hidden, BaseRevision: *change.BaseRevision})
	}
	if len(request.ServerID) != 32 || len(request.MutationID) < 8 || len(request.MutationID) > 128 || len(request.Changes) == 0 || len(request.Changes) > 200 {
		writeBadRequest(w, "invalid preference mutation")
		return
	}
	seen := map[string]bool{}
	for _, change := range request.Changes {
		if strings.TrimSpace(change.MessageKey) == "" || len(change.MessageKey) > 2048 || len(strings.Split(change.MessageKey, "\x1f")) != 2 || strings.HasPrefix(change.MessageKey, "\x1f") || strings.HasSuffix(change.MessageKey, "\x1f") || change.BaseRevision < 0 || seen[change.MessageKey] {
			writeBadRequest(w, "invalid or duplicate chat preference")
			return
		}
		seen[change.MessageKey] = true
	}
	result, err := h.messagePreferences.MutateMessagePreferences(r.Context(), request)
	switch {
	case errors.Is(err, relaydb.ErrPreferenceConflict):
		writeJSON(w, http.StatusConflict, map[string]any{"code": "preference_conflict", "current": result})
		return
	case errors.Is(err, relaydb.ErrPreferenceScope):
		writeJSON(w, http.StatusConflict, map[string]any{"code": "preference_server_changed", "current": result})
		return
	case errors.Is(err, relaydb.ErrPreferenceMutation):
		writeJSON(w, http.StatusConflict, map[string]any{"code": "preference_mutation_reused"})
		return
	case err != nil:
		h.logInternal("update chat preferences", err)
		writeInternalError(w)
		return
	}
	if h.messagePreferenceEvents != nil {
		_ = h.messagePreferenceEvents.Broadcast(r.Context(), realtime.Event{Type: "message-preferences:changed", Data: map[string]any{"revision": result.Revision}})
	}
	writeJSON(w, http.StatusOK, result)
}

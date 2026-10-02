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
	"strings"
)

type readStateService interface {
	ReadState(context.Context) (store.ReadState, error)
	AdvanceReadState(context.Context, store.ReadStateMutation) (store.ReadState, error)
}

func (h *Handlers) SetReadState(service readStateService, events eventBroadcaster) {
	h.readState = service
	h.readStateEvents = events
}
func (h *Handlers) GetReadState(w http.ResponseWriter, r *http.Request) {
	if h.readState == nil {
		writeInternalError(w)
		return
	}
	result, err := h.readState.ReadState(r.Context())
	if err != nil {
		h.logInternal("read state", err)
		writeInternalError(w)
		return
	}
	writeJSON(w, http.StatusOK, result)
}
func (h *Handlers) PatchReadState(w http.ResponseWriter, r *http.Request) {
	if h.readState == nil {
		writeInternalError(w)
		return
	}
	var request store.ReadStateMutation
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 256*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		writeBadRequest(w, "invalid read state")
		return
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		writeBadRequest(w, "invalid read state")
		return
	}
	if len(request.ServerID) != 32 || len(request.Changes) == 0 || len(request.Changes) > 200 {
		writeBadRequest(w, "invalid read state")
		return
	}
	seen := map[string]bool{}
	for _, row := range request.Changes {
		if strings.TrimSpace(row.ChatGUID) == "" || len(row.ChatGUID) > 1024 || row.ReadThrough <= 0 || seen[row.ChatGUID] {
			writeBadRequest(w, "invalid read position")
			return
		}
		seen[row.ChatGUID] = true
	}
	before, err := h.readState.ReadState(r.Context())
	if err != nil {
		writeInternalError(w)
		return
	}
	result, err := h.readState.AdvanceReadState(r.Context(), request)
	if errors.Is(err, relaydb.ErrPreferenceScope) {
		writeJSON(w, http.StatusConflict, map[string]any{"code": "read_server_changed"})
		return
	}
	if err != nil {
		h.logInternal("advance read state", err)
		writeInternalError(w)
		return
	}
	if result.Revision > before.Revision && h.readStateEvents != nil {
		_ = h.readStateEvents.Broadcast(r.Context(), realtime.Event{Type: "read-state:changed", Data: map[string]any{"revision": result.Revision}})
	}
	writeJSON(w, http.StatusOK, result)
}

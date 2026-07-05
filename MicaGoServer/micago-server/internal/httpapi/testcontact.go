package httpapi

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"strings"

	"micagoserver/internal/realtime"
	"micagoserver/internal/relaydb"
	"micagoserver/internal/store"
	"micagoserver/internal/testcontact"
)

// testContactStore is the relay-backed loopback for the offline test contact.
type testContactStore interface {
	TestContactEnabled(ctx context.Context) (bool, error)
	SetTestContactEnabled(ctx context.Context, enabled bool) error
	AppendTestOutgoingMessage(ctx context.Context, text string) (*store.MessageJSON, error)
	AppendTestInboundMessage(ctx context.Context, text string) (*store.MessageJSON, error)
	TestContactWelcome(ctx context.Context) (*store.MessageJSON, error)
}

// SetTestContactService wires the offline test-contact loopback. Nil means the
// endpoints report it as unavailable and the chat simply never exists.
func (h *Handlers) SetTestContactService(svc testContactStore) { h.testContact = svc }

// GetTestContact reports whether the offline test contact is on.
func (h *Handlers) GetTestContact(w http.ResponseWriter, r *http.Request) {
	if h.testContact == nil {
		writeJSON(w, http.StatusOK, map[string]any{"available": false, "enabled": false})
		return
	}
	enabled, err := h.testContact.TestContactEnabled(r.Context())
	if err != nil {
		h.logInternal("test contact get", err)
		writeInternalError(w)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"available": true,
		"enabled":   enabled,
		"handle":    testcontact.Handle,
		"chatGuid":  testcontact.ChatGUID,
	})
}

// PutTestContact turns the offline test contact on or off. Enabling seeds the
// synthetic chat + greeting and broadcasts the greeting so an open client shows
// it immediately; disabling removes every row.
func (h *Handlers) PutTestContact(w http.ResponseWriter, r *http.Request) {
	if h.testContact == nil {
		writeInternalError(w)
		return
	}
	var req struct {
		Enabled bool `json:"enabled"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeBadRequest(w, "invalid JSON body")
		return
	}
	if err := h.testContact.SetTestContactEnabled(r.Context(), req.Enabled); err != nil {
		h.logInternal("test contact set", err)
		writeInternalError(w)
		return
	}
	if req.Enabled && h.send != nil && h.send.Events != nil {
		if msg, err := h.testContact.TestContactWelcome(r.Context()); err == nil && msg != nil {
			_ = h.send.Events.Broadcast(r.Context(), realtime.Event{Type: "message:new", Data: *msg})
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"enabled":  req.Enabled,
		"chatGuid": testcontact.ChatGUID,
	})
}

// PostTestContactInbound injects a message *from* the test contact (typed in the
// Companion's Debug card) as an incoming row and broadcasts it, so it pushes to
// the client exactly like a received iMessage.
func (h *Handlers) PostTestContactInbound(w http.ResponseWriter, r *http.Request) {
	if h.testContact == nil {
		writeInternalError(w)
		return
	}
	enabled, err := h.testContact.TestContactEnabled(r.Context())
	if err != nil {
		h.logInternal("test contact check", err)
		writeInternalError(w)
		return
	}
	if !enabled {
		writeBadRequest(w, "test contact is disabled")
		return
	}
	var req struct {
		Text string `json:"text"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeBadRequest(w, "invalid JSON body")
		return
	}
	req.Text = strings.TrimSpace(req.Text)
	if req.Text == "" {
		writeBadRequest(w, "text is required")
		return
	}
	msg, err := h.testContact.AppendTestInboundMessage(r.Context(), req.Text)
	if err != nil || msg == nil {
		h.logInternal("test contact inbound", err)
		writeInternalError(w)
		return
	}
	if h.send != nil && h.send.Events != nil {
		_ = h.send.Events.Broadcast(r.Context(), realtime.Event{Type: "message:new", Data: *msg})
	}
	h.dispatchTestContactNotification(r.Context(), *msg)
	writeJSON(w, http.StatusOK, msg)
}

func (h *Handlers) dispatchTestContactNotification(ctx context.Context, msg store.MessageJSON) {
	if h.notify == nil || h.devices == nil {
		return
	}
	devices, err := h.devices.ListDevices(ctx)
	if err != nil {
		h.logInternal("test contact list devices", err)
		return
	}
	pushReady := 0
	for _, device := range devices {
		if device.PushProvider != "none" && device.PushEnabled && device.PushToken != nil && strings.TrimSpace(*device.PushToken) != "" {
			pushReady++
		}
	}
	log.Printf("test contact push dispatch: registered_devices=%d push_ready_devices=%d notifications_enabled=%t preview=%s",
		len(devices), pushReady, h.notify.Enabled(), h.notify.PreviewMode())
	identifier := testcontact.Handle
	display := testcontact.DisplayName
	event := relaydb.NotificationEvent{
		ChatGUID:       testcontact.ChatGUID,
		ChatIdentifier: &identifier,
		ChatDisplay:    &display,
		IsGroup:        false,
		Message:        msg,
	}
	if err := h.notify.DispatchNewMessages(ctx, devices, []relaydb.NotificationEvent{event}); err != nil {
		log.Printf("test contact push dispatch: %v", err)
	}
}

// sendTestLoopback records a client message to the test chat as a delivered
// outgoing row and confirms it over the normal send:match path — never touching
// Messages.app. Called from SendText for the synthetic chat guid.
func (h *Handlers) sendTestLoopback(w http.ResponseWriter, r *http.Request) {
	if h.testContact == nil {
		writeNotFound(w, "chat not found")
		return
	}
	enabled, err := h.testContact.TestContactEnabled(r.Context())
	if err != nil {
		h.logInternal("test contact check", err)
		writeInternalError(w)
		return
	}
	if !enabled {
		writeNotFound(w, "chat not found")
		return
	}

	var req sendRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeBadRequest(w, "invalid JSON body")
		return
	}
	req.TempGUID = strings.TrimSpace(req.TempGUID)
	req.Message = strings.TrimSpace(req.Message)
	if req.TempGUID == "" {
		writeBadRequest(w, "tempGuid is required")
		return
	}
	if req.Message == "" {
		writeBadRequest(w, "message is required")
		return
	}

	msg, err := h.testContact.AppendTestOutgoingMessage(r.Context(), req.Message)
	if err != nil || msg == nil {
		h.logInternal("test contact append", err)
		writeInternalError(w)
		return
	}
	h.broadcastSendMatch(r.Context(), req.TempGUID, *msg)
	writeJSON(w, http.StatusOK, msg)
}

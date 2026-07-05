package httpapi

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"micagoserver/internal/config"
	"micagoserver/internal/relaydb"
	"micagoserver/internal/store"
	"micagoserver/internal/testcontact"
)

type fakeTestContact struct {
	enabled  bool
	appended []string
	inbound  []string
}

func (f *fakeTestContact) TestContactEnabled(context.Context) (bool, error) { return f.enabled, nil }
func (f *fakeTestContact) SetTestContactEnabled(_ context.Context, enabled bool) error {
	f.enabled = enabled
	return nil
}
func (f *fakeTestContact) AppendTestOutgoingMessage(_ context.Context, text string) (*store.MessageJSON, error) {
	f.appended = append(f.appended, text)
	guid := "micago-test-out-1"
	chat := testcontact.ChatGUID
	return &store.MessageJSON{GUID: guid, ChatGUID: &chat, Text: &text, IsFromMe: true}, nil
}
func (f *fakeTestContact) AppendTestInboundMessage(_ context.Context, text string) (*store.MessageJSON, error) {
	f.inbound = append(f.inbound, text)
	guid := "micago-test-in-1"
	chat := testcontact.ChatGUID
	return &store.MessageJSON{GUID: guid, ChatGUID: &chat, Text: &text}, nil
}
func (f *fakeTestContact) TestContactWelcome(context.Context) (*store.MessageJSON, error) {
	chat := testcontact.ChatGUID
	txt := testcontact.WelcomeText
	return &store.MessageJSON{GUID: testcontact.WelcomeGUID, ChatGUID: &chat, Text: &txt}, nil
}

func TestTestContactEndpointsToggle(t *testing.T) {
	tc := &fakeTestContact{}
	h := newTestHandlers(&stubQueries{})
	h.SetTestContactService(tc)

	// GET reports disabled + available.
	rec := httptest.NewRecorder()
	h.GetTestContact(rec, httptest.NewRequest(http.MethodGet, "/api/test-contact", nil))
	var got map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &got)
	if got["available"] != true || got["enabled"] != false {
		t.Fatalf("unexpected GET body: %v", got)
	}

	// PUT enable flips state.
	rec = httptest.NewRecorder()
	h.PutTestContact(rec, httptest.NewRequest(http.MethodPut, "/api/test-contact", strings.NewReader(`{"enabled":true}`)))
	if rec.Code != http.StatusOK || !tc.enabled {
		t.Fatalf("enable failed: code=%d enabled=%v", rec.Code, tc.enabled)
	}
}

func TestSendTextLoopsBackForTestChat(t *testing.T) {
	tc := &fakeTestContact{enabled: true}
	h := newTestHandlers(&stubQueries{})
	h.SetTestContactService(tc)

	body := strings.NewReader(`{"tempGuid":"t-1","message":"hi"}`)
	req := httptest.NewRequest(http.MethodPost, "/api/chats/x/send", body)
	req.SetPathValue("guid", testcontact.ChatGUID)
	rec := httptest.NewRecorder()

	// h.send is nil here; a normal chat would 500, but the test chat must loop
	// back without touching the send machinery.
	h.SendText(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 loopback, got %d (%s)", rec.Code, rec.Body.String())
	}
	if len(tc.appended) != 1 || tc.appended[0] != "hi" {
		t.Fatalf("expected message recorded, got %v", tc.appended)
	}
}

func TestSendTextTestChatRejectedWhenDisabled(t *testing.T) {
	tc := &fakeTestContact{enabled: false}
	h := newTestHandlers(&stubQueries{})
	h.SetTestContactService(tc)

	req := httptest.NewRequest(http.MethodPost, "/api/chats/x/send", strings.NewReader(`{"tempGuid":"t","message":"hi"}`))
	req.SetPathValue("guid", testcontact.ChatGUID)
	rec := httptest.NewRecorder()
	h.SendText(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("disabled test chat should 404, got %d", rec.Code)
	}
}

func TestPostTestContactInbound(t *testing.T) {
	tc := &fakeTestContact{enabled: true}
	h := newTestHandlers(&stubQueries{})
	h.SetTestContactService(tc)

	req := httptest.NewRequest(http.MethodPost, "/api/test-contact/inbound", strings.NewReader(`{"text":"ping"}`))
	rec := httptest.NewRecorder()
	h.PostTestContactInbound(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d (%s)", rec.Code, rec.Body.String())
	}
	if len(tc.inbound) != 1 || tc.inbound[0] != "ping" {
		t.Fatalf("expected inbound recorded, got %v", tc.inbound)
	}
}

type captureTestNotifier struct {
	stubNotifier
	devices []store.DeviceRecord
	events  []relaydb.NotificationEvent
}

func (c *captureTestNotifier) DispatchNewMessages(_ context.Context, devices []store.DeviceRecord, events []relaydb.NotificationEvent) error {
	c.devices = append([]store.DeviceRecord(nil), devices...)
	c.events = append([]relaydb.NotificationEvent(nil), events...)
	return nil
}

func TestPostTestContactInboundDispatchesNotification(t *testing.T) {
	tc := &fakeTestContact{enabled: true}
	pushToken := "fcm-token"
	devices := &stubDeviceStore{devices: map[string]store.DeviceRecord{
		"phone": {
			ID:           "phone",
			Name:         "Android",
			PushProvider: "fcm",
			PushEnabled:  true,
			PushToken:    &pushToken,
		},
	}}
	notifier := &captureTestNotifier{}
	h := NewHandlers(
		&stubQueries{},
		log.New(io.Discard, "", 0),
		nil,
		nil,
		"",
		devices,
		notifier,
		config.Config{WebhookURL: "", HTTPAddr: "127.0.0.1:3000"},
		StatusDeps{},
	)
	h.SetTestContactService(tc)

	req := httptest.NewRequest(http.MethodPost, "/api/test-contact/inbound", strings.NewReader(`{"text":"ping"}`))
	rec := httptest.NewRecorder()
	h.PostTestContactInbound(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d (%s)", rec.Code, rec.Body.String())
	}
	if len(notifier.devices) != 1 || notifier.devices[0].ID != "phone" {
		t.Fatalf("expected registered device passed to notifier, got %#v", notifier.devices)
	}
	if len(notifier.events) != 1 {
		t.Fatalf("expected one notification event, got %d", len(notifier.events))
	}
	event := notifier.events[0]
	if event.ChatGUID != testcontact.ChatGUID {
		t.Fatalf("expected test chat guid %q, got %q", testcontact.ChatGUID, event.ChatGUID)
	}
	if event.ChatLabel() != testcontact.DisplayName {
		t.Fatalf("expected display name %q, got %q", testcontact.DisplayName, event.ChatLabel())
	}
	if event.Message.GUID != "micago-test-in-1" {
		t.Fatalf("expected inbound message guid, got %q", event.Message.GUID)
	}
}

func TestPostTestContactInboundRejectedWhenDisabled(t *testing.T) {
	tc := &fakeTestContact{enabled: false}
	h := newTestHandlers(&stubQueries{})
	h.SetTestContactService(tc)

	req := httptest.NewRequest(http.MethodPost, "/api/test-contact/inbound", strings.NewReader(`{"text":"ping"}`))
	rec := httptest.NewRecorder()
	h.PostTestContactInbound(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("disabled inbound should 400, got %d", rec.Code)
	}
}

func TestSendAttachmentRejectedForTestChat(t *testing.T) {
	tc := &fakeTestContact{enabled: true}
	h := newTestHandlers(&stubQueries{})
	h.SetTestContactService(tc)

	req := httptest.NewRequest(http.MethodPost, "/api/chats/x/send-attachment", nil)
	req.SetPathValue("guid", testcontact.ChatGUID)
	rec := httptest.NewRecorder()
	h.SendAttachment(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("attachment to test chat should 400, got %d", rec.Code)
	}
}

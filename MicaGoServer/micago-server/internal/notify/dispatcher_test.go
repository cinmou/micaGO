package notify

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"testing"

	"micagoserver/internal/config"
	"micagoserver/internal/relaydb"
	"micagoserver/internal/store"
)

func TestNoneProviderNoOp(t *testing.T) {
	if err := (NoneProvider{}).Send(context.Background(), store.DeviceRecord{}, Notification{}); err != nil {
		t.Fatalf("expected none provider to no-op, got %v", err)
	}
}

func TestDispatcherSendTestUsesWebhookProvider(t *testing.T) {
	var got map[string]any
	dispatcher := NewDispatcher(config.Config{
		NotificationsEnabled: true,
		NotificationPreview:  "sender",
		WebhookURL:           "https://example.test/webhook",
	})
	dispatcher.providers["webhook"] = WebhookProvider{
		URL: "https://example.test/webhook",
		Client: &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
			defer req.Body.Close()
			if err := json.NewDecoder(req.Body).Decode(&got); err != nil {
				t.Fatal(err)
			}
			return &http.Response{
				StatusCode: http.StatusOK,
				Body:       io.NopCloser(bytes.NewReader(nil)),
				Header:     make(http.Header),
			}, nil
		})},
	}
	device := store.DeviceRecord{
		ID:           "dev-1",
		Name:         "Device",
		Platform:     "android",
		ClientType:   "flutter",
		PushProvider: "webhook",
		PushEnabled:  true,
	}
	if err := dispatcher.SendTest(context.Background(), device); err != nil {
		t.Fatal(err)
	}
	if got["notification"] == nil {
		t.Fatalf("expected webhook payload, got %#v", got)
	}
}

func TestDispatcherBuildsNotificationPreview(t *testing.T) {
	text := "hello"
	event := relaydb.NotificationEvent{
		ChatGUID:       "chat-1",
		ChatIdentifier: ptr("chat@example.com"),
		Message: store.MessageJSON{
			GUID:   "msg-1",
			Text:   &text,
			Handle: &store.HandleJSON{ID: "+15550001"},
		},
	}
	notification := buildNotification(event, "sender_and_text")
	if notification.Title != "chat@example.com" {
		t.Fatalf("expected sender title, got %q", notification.Title)
	}
	if notification.Body != "hello" {
		t.Fatalf("expected text body, got %q", notification.Body)
	}
	// C31: the raw handle is carried so the client can fall back / resolve it.
	if notification.Handle != "+15550001" {
		t.Fatalf("expected handle, got %q", notification.Handle)
	}
	if notification.SenderName != "chat@example.com" || notification.ConversationTitle != "chat@example.com" || notification.IsGroup {
		t.Fatalf("unexpected one-to-one conversation fields: %+v", notification)
	}
}

func TestDispatcherBuildsGroupConversationNotification(t *testing.T) {
	text := "see you there"
	event := relaydb.NotificationEvent{
		ChatGUID:    "any;+;group",
		ChatDisplay: ptr("Family"),
		IsGroup:     true,
		Message: store.MessageJSON{
			GUID:   "msg-1",
			Text:   &text,
			Handle: &store.HandleJSON{ID: "+15550001"},
		},
	}
	notification := buildNotification(event, "sender_and_text")
	if notification.Title != "Family" || notification.ConversationTitle != "Family" {
		t.Fatalf("expected group title as conversation title, got %+v", notification)
	}
	if notification.SenderName != "+15550001" || !notification.IsGroup {
		t.Fatalf("expected sender person for group notification, got %+v", notification)
	}
	if notification.Body != "see you there" {
		t.Fatalf("expected body preview, got %q", notification.Body)
	}
}

func TestDispatcherUsesContactCacheForNotificationNames(t *testing.T) {
	text := "see you there"
	dispatcher := NewDispatcher(config.Config{})
	dispatcher.SetContactCache([]ContactEntry{{
		Name:      "Alice",
		Addresses: []string{"+15550001"},
	}})
	event := relaydb.NotificationEvent{
		ChatGUID:    "any;+;group",
		ChatDisplay: ptr("Family"),
		IsGroup:     true,
		Message: store.MessageJSON{
			GUID:   "msg-1",
			Text:   &text,
			Handle: &store.HandleJSON{ID: "+15550001"},
		},
	}
	notification := dispatcher.buildNotification(event, "sender_and_text")
	if notification.Title != "Family" || notification.ConversationTitle != "Family" {
		t.Fatalf("expected group title unchanged, got %+v", notification)
	}
	if notification.SenderName != "Alice" {
		t.Fatalf("expected contact sender name, got %+v", notification)
	}
}

func TestBuildNotificationPreviewModes(t *testing.T) {
	text := "secret text"
	event := relaydb.NotificationEvent{
		ChatGUID:       "chat-1",
		ChatIdentifier: ptr("+15550001"),
		Message:        store.MessageJSON{GUID: "msg-1", Text: &text},
	}
	// "none": a generic title, no sender, no text (privacy).
	none := buildNotification(event, "none")
	if none.Title != "New message" || none.Body != "" {
		t.Fatalf("none mode leaked content: %+v", none)
	}
	// "sender": who, not what.
	sender := buildNotification(event, "sender")
	if sender.Title != "+15550001" || sender.Body != "" {
		t.Fatalf("sender mode: title=%q body=%q", sender.Title, sender.Body)
	}
}

func TestBuildNotificationFallsBackToChatIdentifierHandle(t *testing.T) {
	text := "hello from test"
	event := relaydb.NotificationEvent{
		ChatGUID:       "iMessage;-;test@micago.cinmou",
		ChatIdentifier: ptr("test@micago.cinmou"),
		ChatDisplay:    ptr("MicaGo Test"),
		Message: store.MessageJSON{
			GUID: "msg-test",
			Text: &text,
		},
	}

	notification := buildNotification(event, "sender_and_text")

	if notification.Handle != "test@micago.cinmou" {
		t.Fatalf("expected chat identifier fallback handle, got %q", notification.Handle)
	}
	if notification.Title != "MicaGo Test" || notification.SenderName != "MicaGo Test" {
		t.Fatalf("expected test contact title/sender, got %+v", notification)
	}
	if notification.Body != text {
		t.Fatalf("expected body preview, got %q", notification.Body)
	}
}

// fakeProvider captures what the dispatcher sends (C22) so we can assert the
// BlueBubbles-style payload + that disabled devices are skipped.
type fakeProvider struct {
	sent []struct {
		device       store.DeviceRecord
		notification Notification
	}
}

func (f *fakeProvider) Name() string { return "fcm" }
func (f *fakeProvider) Send(_ context.Context, d store.DeviceRecord, n Notification) error {
	f.sent = append(f.sent, struct {
		device       store.DeviceRecord
		notification Notification
	}{d, n})
	return nil
}

func TestDispatchNewMessagesFakeProvider(t *testing.T) {
	fake := &fakeProvider{}
	d := NewDispatcher(config.Config{NotificationsEnabled: true, NotificationPreview: "sender"})
	d.providers["fcm"] = fake

	rowID := int64(4242)
	text := "yo"
	events := []relaydb.NotificationEvent{{
		ChatGUID:       "chat-1",
		ChatIdentifier: ptr("+15550001"),
		Message: store.MessageJSON{
			GUID:        "msg-1",
			Text:        &text,
			SourceRowID: &rowID,
		},
	}}
	devices := []store.DeviceRecord{
		{ID: "on", PushProvider: "fcm", PushEnabled: true},
		{ID: "off", PushProvider: "fcm", PushEnabled: false},  // disabled → skipped
		{ID: "none", PushProvider: "none", PushEnabled: true}, // provider none → skipped
	}

	if err := d.DispatchNewMessages(context.Background(), devices, events); err != nil {
		t.Fatal(err)
	}
	if len(fake.sent) != 1 {
		t.Fatalf("expected 1 push (only the enabled fcm device), got %d", len(fake.sent))
	}
	got := fake.sent[0]
	if got.device.ID != "on" {
		t.Fatalf("expected push to the enabled device, got %q", got.device.ID)
	}
	// BlueBubbles-style data fields + the C22 delta cursor.
	if got.notification.Type != "message:new" || got.notification.ChatGUID != "chat-1" ||
		got.notification.MessageGUID != "msg-1" || got.notification.SourceRowID != 4242 {
		t.Fatalf("unexpected push payload: %#v", got.notification)
	}
}

func TestDispatchUsesAttachmentPreviewWhenTextIsEmpty(t *testing.T) {
	fake := &fakeProvider{}
	d := NewDispatcher(config.Config{NotificationsEnabled: true, NotificationPreview: "sender_and_text"})
	d.providers["fcm"] = fake

	events := []relaydb.NotificationEvent{{
		ChatGUID:       "chat-1",
		ChatIdentifier: ptr("Photos"),
		Message: store.MessageJSON{
			GUID: "msg-photo",
			Attachments: []store.AttachmentJSON{{
				GUID:           "att-1",
				MimeType:       ptr("image/jpeg"),
				AttachmentKind: "image",
			}},
		},
	}}
	devices := []store.DeviceRecord{{ID: "on", PushProvider: "fcm", PushEnabled: true}}

	if err := d.DispatchNewMessages(context.Background(), devices, events); err != nil {
		t.Fatal(err)
	}
	if len(fake.sent) != 1 {
		t.Fatalf("expected 1 push, got %d", len(fake.sent))
	}
	if fake.sent[0].notification.Body != "（图片）" {
		t.Fatalf("expected image preview label, got %q", fake.sent[0].notification.Body)
	}
}

func TestDispatchSkipsOwnMessages(t *testing.T) {
	fake := &fakeProvider{}
	d := NewDispatcher(config.Config{NotificationsEnabled: true, NotificationPreview: "sender"})
	d.providers["fcm"] = fake
	events := []relaydb.NotificationEvent{{
		ChatGUID: "chat-1",
		Message:  store.MessageJSON{GUID: "mine", IsFromMe: true},
	}}
	devices := []store.DeviceRecord{{ID: "on", PushProvider: "fcm", PushEnabled: true}}
	if err := d.DispatchNewMessages(context.Background(), devices, events); err != nil {
		t.Fatal(err)
	}
	if len(fake.sent) != 0 {
		t.Fatalf("expected no push for an outgoing message, got %d", len(fake.sent))
	}
}

func ptr[T any](v T) *T { return &v }

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(req *http.Request) (*http.Response, error) {
	return f(req)
}

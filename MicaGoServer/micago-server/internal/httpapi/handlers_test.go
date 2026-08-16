package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"micagoserver/internal/config"
	"micagoserver/internal/realtime"
	"micagoserver/internal/relaydb"
	micasend "micagoserver/internal/send"
	"micagoserver/internal/store"
	"micagoserver/internal/version"
)

type stubQueries struct {
	recentService      string
	recentIncludeEmpty bool
	chatService        string
	chatWithArchived   bool
	chatIncludeDebug   bool
	chatMessagesEmpty  bool
	chatMessages       []store.MessageJSON
	match              *store.MessageJSON
}

func (s *stubQueries) ListRecentMessages(_ context.Context, _ int, _ int, service string, includeDebug bool) ([]store.MessageJSON, error) {
	s.recentService = service
	s.recentIncludeEmpty = includeDebug
	return filterStubRows(s.chatMessages, includeDebug), nil
}

func (s *stubQueries) ListChats(_ context.Context, _ int, _ int, withArchived bool, service string, includeDebug bool) ([]store.ChatJSON, error) {
	s.chatService = service
	s.chatWithArchived = withArchived
	s.chatIncludeDebug = includeDebug
	return []store.ChatJSON{}, nil
}

func (s *stubQueries) ChatExists(_ context.Context, _ string) (bool, error) {
	return true, nil
}

func (s *stubQueries) GetChatInfo(_ context.Context, guid string) (*store.ChatInfo, error) {
	service := serviceIMessage
	return &store.ChatInfo{GUID: guid, ServiceName: &service}, nil
}

func (s *stubQueries) ListChatMessages(_ context.Context, _ string, _ int, _ int, includeDebug bool) ([]store.MessageJSON, error) {
	s.chatMessagesEmpty = includeDebug
	// Model the relay contract: the renderable timeline is filtered in the query
	// layer (here, the stub) — the handler no longer post-filters. includeDebug
	// returns the raw timeline for the Inspector.
	return filterStubRows(s.chatMessages, includeDebug), nil
}

func (s *stubQueries) ListMergedMessages(_ context.Context, _ []string, limit int, _ *int64, _ *int64, includeDebug bool) ([]store.MessageJSON, error) {
	rows := filterStubRows(s.chatMessages, includeDebug)
	if len(rows) > limit {
		rows = rows[:limit]
	}
	return rows, nil
}

func (s *stubQueries) ListMessagesSince(_ context.Context, since int64, _ int) (relaydb.DeltaResult, error) {
	return relaydb.DeltaResult{Messages: []store.MessageJSON{}, ChatGUIDs: []string{}, Cursor: since}, nil
}

// filterStubRows mimics the relay's SQL-level renderable filter: drop debug-only
// rows unless the caller asked for the raw timeline.
func filterStubRows(rows []store.MessageJSON, includeDebug bool) []store.MessageJSON {
	out := make([]store.MessageJSON, 0, len(rows))
	for _, m := range rows {
		if !includeDebug && m.IsDebugOnly {
			continue
		}
		out = append(out, m)
	}
	return out
}

func (s *stubQueries) FindOutgoingMessageMatch(_ context.Context, _ string, _ string, _ int64, _ map[string]struct{}) (*store.MessageJSON, error) {
	return s.match, nil
}

type stubDeviceStore struct {
	devices map[string]store.DeviceRecord
}

func (s *stubDeviceStore) UpsertDevice(_ context.Context, device store.DeviceRecord) (*store.DeviceRecord, error) {
	if s.devices == nil {
		s.devices = map[string]store.DeviceRecord{}
	}
	s.devices[device.ID] = device
	copy := s.devices[device.ID]
	return &copy, nil
}

func (s *stubDeviceStore) GetDeviceByID(_ context.Context, id string) (*store.DeviceRecord, error) {
	device, ok := s.devices[id]
	if !ok {
		return nil, nil
	}
	copy := device
	return &copy, nil
}

func (s *stubDeviceStore) ListDevices(_ context.Context) ([]store.DeviceRecord, error) {
	out := make([]store.DeviceRecord, 0, len(s.devices))
	for _, device := range s.devices {
		out = append(out, device)
	}
	return out, nil
}

func (s *stubDeviceStore) UpdateDeviceHeartbeat(_ context.Context, id string, at int64) (*store.DeviceRecord, error) {
	device, ok := s.devices[id]
	if !ok {
		return nil, nil
	}
	device.LastSeenAt = &at
	device.UpdatedAt = at
	s.devices[id] = device
	copy := device
	return &copy, nil
}

func (s *stubDeviceStore) DeleteDevice(_ context.Context, id string) error {
	delete(s.devices, id)
	return nil
}

type stubNotifier struct {
	err  error
	sent *int
}

func (s stubNotifier) SendTest(context.Context, store.DeviceRecord) error {
	if s.sent != nil {
		*s.sent++
	}
	return s.err
}
func (s stubNotifier) DispatchNewMessages(context.Context, []store.DeviceRecord, []relaydb.NotificationEvent) error {
	return s.err
}
func (s stubNotifier) ProviderNames() []string {
	return []string{"none", "webhook", "fcm", "hms", "harmony_push", "ntfy"}
}
func (s stubNotifier) ImplementedProviders() []string { return []string{"none", "webhook"} }
func (s stubNotifier) Enabled() bool                  { return true }
func (s stubNotifier) PreviewMode() string            { return "sender" }
func (s stubNotifier) DefaultProvider() string        { return "none" }

func newTestHandlers(queries *stubQueries) *Handlers {
	return NewHandlers(
		queries,
		log.New(io.Discard, "", 0),
		nil,
		nil,
		"",
		&stubDeviceStore{},
		stubNotifier{},
		config.Config{WebhookURL: "", HTTPAddr: "127.0.0.1:3000"},
		StatusDeps{},
	)
}

func TestGetRecentMessagesDefaultsToIMessageWithoutEmpty(t *testing.T) {
	queries := &stubQueries{}
	handlers := newTestHandlers(queries)

	req := httptest.NewRequest(http.MethodGet, "/api/messages/recent", nil)
	rec := httptest.NewRecorder()

	handlers.GetRecentMessages(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	if queries.recentService != defaultService {
		t.Fatalf("expected default service %q, got %q", defaultService, queries.recentService)
	}
	if queries.recentIncludeEmpty {
		t.Fatal("expected includeEmpty to default to false")
	}
}

func TestGetChatsUsesRequestedServiceAndArchivedFlag(t *testing.T) {
	queries := &stubQueries{}
	handlers := newTestHandlers(queries)

	req := httptest.NewRequest(http.MethodGet, "/api/chats?service=all&withArchived=true", nil)
	rec := httptest.NewRecorder()

	handlers.GetChats(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	if queries.chatService != serviceAll {
		t.Fatalf("expected service %q, got %q", serviceAll, queries.chatService)
	}
	if !queries.chatWithArchived {
		t.Fatal("expected withArchived to be true")
	}
}

func TestGetChatsPassesDebugFlag(t *testing.T) {
	queries := &stubQueries{}
	handlers := newTestHandlers(queries)
	req := httptest.NewRequest(http.MethodGet, "/api/chats?debug=true", nil)
	rec := httptest.NewRecorder()
	handlers.GetChats(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	if !queries.chatIncludeDebug {
		t.Fatal("expected includeDebug=true to be forwarded")
	}
}

func TestGetChatMessagesFiltersDebugOnlyByDefault(t *testing.T) {
	debugRow := store.MessageJSON{GUID: "noise", IsDebugOnly: true}
	textRow := store.MessageJSON{GUID: "real", IsDebugOnly: false}

	// Default: renderable timeline only.
	queries := &stubQueries{chatMessages: []store.MessageJSON{textRow, debugRow}}
	handlers := newTestHandlers(queries)
	req := httptest.NewRequest(http.MethodGet, "/api/chats/c1/messages", nil)
	rec := httptest.NewRecorder()
	handlers.GetChatMessages(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	var resp store.MessageListResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(resp.Data) != 1 || resp.Data[0].GUID != "real" {
		t.Fatalf("default should drop debug-only rows, got %d rows", len(resp.Data))
	}

	// debug=true: include the raw timeline.
	queries2 := &stubQueries{chatMessages: []store.MessageJSON{textRow, debugRow}}
	handlers2 := newTestHandlers(queries2)
	req2 := httptest.NewRequest(http.MethodGet, "/api/chats/c1/messages?debug=true", nil)
	rec2 := httptest.NewRecorder()
	handlers2.GetChatMessages(rec2, req2)
	var resp2 store.MessageListResponse
	if err := json.Unmarshal(rec2.Body.Bytes(), &resp2); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(resp2.Data) != 2 {
		t.Fatalf("debug=true should include all rows, got %d", len(resp2.Data))
	}
}

func TestGetMergedMessageHistoryReturnsOpaqueCursor(t *testing.T) {
	date3, row3 := int64(3000), int64(3)
	date2, row2 := int64(2000), int64(2)
	routeA, routeB := "route-a", "route-b"
	queries := &stubQueries{chatMessages: []store.MessageJSON{
		{GUID: "m3", ChatGUID: &routeB, DateCreated: &date3, SourceRowID: &row3},
		{GUID: "m2", ChatGUID: &routeA, DateCreated: &date2, SourceRowID: &row2},
	}}
	handlers := newTestHandlers(queries)
	req := httptest.NewRequest(http.MethodGet, "/api/messages/history?chatGuid=route-a&chatGuid=route-b&limit=1", nil)
	rec := httptest.NewRecorder()
	handlers.GetMergedMessageHistory(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	var response store.MessageHistoryResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if len(response.Data) != 1 || response.Data[0].GUID != "m3" || !response.HasMore || response.NextCursor == "" {
		t.Fatalf("unexpected history response: %+v", response)
	}
	if _, _, err := decodeHistoryCursor(response.NextCursor); err != nil {
		t.Fatalf("cursor is not decodable: %v", err)
	}
}

func TestGetRecentMessagesRejectsInvalidService(t *testing.T) {
	queries := &stubQueries{}
	handlers := newTestHandlers(queries)

	req := httptest.NewRequest(http.MethodGet, "/api/messages/recent?service=whatsapp", nil)
	rec := httptest.NewRecorder()

	handlers.GetRecentMessages(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "service must be one of") {
		t.Fatalf("unexpected body: %s", rec.Body.String())
	}
}

func TestGetChatMessagesIncludeEmptyParsing(t *testing.T) {
	queries := &stubQueries{}
	handlers := newTestHandlers(queries)

	req := httptest.NewRequest(http.MethodGet, "/api/chats/chat-guid/messages?includeEmpty=true", nil)
	req.SetPathValue("guid", "chat-guid")
	rec := httptest.NewRecorder()

	handlers.GetChatMessages(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	if !queries.chatMessagesEmpty {
		t.Fatal("expected includeEmpty to be true")
	}
}

type duplicatePendingManager struct{}

func (duplicatePendingManager) Add(micasend.PendingSend) error                    { return micasend.ErrDuplicateTempGUID }
func (duplicatePendingManager) Remove(string)                                     {}
func (duplicatePendingManager) Has(string) bool                                   { return true }
func (duplicatePendingManager) Resolve(string, string, int64) bool                { return true }
func (duplicatePendingManager) Reject(string, string)                             {}
func (duplicatePendingManager) MarkSentUnconfirmed(string, string, time.Duration) {}
func (duplicatePendingManager) ClaimedSnapshot() map[string]struct{}              { return nil }

type noopSender struct{}

func (noopSender) SendText(context.Context, string, string) error       { return nil }
func (noopSender) SendAttachment(context.Context, string, string) error { return nil }

func TestSendTextRejectsDuplicateTempGUID(t *testing.T) {
	queries := &stubQueries{}
	handlers := NewHandlers(queries, log.New(io.Discard, "", 0), &SendDependencies{
		Pending: duplicatePendingManager{},
		Sender:  noopSender{},
	}, nil, "", &stubDeviceStore{}, stubNotifier{}, config.Config{HTTPAddr: "127.0.0.1:3000"}, StatusDeps{})

	req := httptest.NewRequest(http.MethodPost, "/api/chats/chat-guid/send", strings.NewReader(`{"tempGuid":"dup","message":"hello"}`))
	req.SetPathValue("guid", "chat-guid")
	rec := httptest.NewRecorder()

	handlers.SendText(rec, req)

	if rec.Code != http.StatusConflict {
		t.Fatalf("expected 409, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "tempGuid is already pending") {
		t.Fatalf("unexpected body: %s", rec.Body.String())
	}
}

type fakePendingManager struct {
	added    map[string]bool
	removed  []string
	claimed  map[string]string
	rejected map[string]string
}

func (m *fakePendingManager) Add(p micasend.PendingSend) error {
	if m.added == nil {
		m.added = map[string]bool{}
	}
	if m.added[p.TempGUID] {
		return micasend.ErrDuplicateTempGUID
	}
	m.added[p.TempGUID] = true
	return nil
}

func (m *fakePendingManager) Remove(tempGUID string) {
	m.removed = append(m.removed, tempGUID)
	delete(m.added, tempGUID)
}

func (m *fakePendingManager) Has(tempGUID string) bool { return m.added[tempGUID] }

func (m *fakePendingManager) Resolve(tempGUID, matchedGUID string, _ int64) bool {
	if m.claimed == nil {
		m.claimed = map[string]string{}
	}
	if owner, ok := m.claimed[matchedGUID]; ok && owner != tempGUID {
		return false
	}
	m.claimed[matchedGUID] = tempGUID
	return true
}

func (m *fakePendingManager) Reject(tempGUID, reason string) {
	if m.rejected == nil {
		m.rejected = map[string]string{}
	}
	m.rejected[tempGUID] = reason
}

func (m *fakePendingManager) MarkSentUnconfirmed(tempGUID, reason string, _ time.Duration) {
	if m.rejected == nil {
		m.rejected = map[string]string{}
	}
	m.rejected[tempGUID] = reason
}

func (m *fakePendingManager) ClaimedSnapshot() map[string]struct{} {
	out := map[string]struct{}{}
	for guid := range m.claimed {
		out[guid] = struct{}{}
	}
	return out
}

type errorSender struct{}

func (errorSender) SendText(context.Context, string, string) error { return errors.New("boom") }
func (errorSender) SendAttachment(context.Context, string, string) error {
	return errors.New("boom")
}

func TestSendTextCleansPendingOnFailure(t *testing.T) {
	queries := &stubQueries{}
	pending := &fakePendingManager{}
	handlers := NewHandlers(queries, log.New(io.Discard, "", 0), &SendDependencies{
		Pending: pending,
		Sender:  errorSender{},
	}, nil, "", &stubDeviceStore{}, stubNotifier{}, config.Config{HTTPAddr: "127.0.0.1:3000"}, StatusDeps{})

	req := httptest.NewRequest(http.MethodPost, "/api/chats/chat-guid/send", strings.NewReader(`{"tempGuid":"one","message":"hello"}`))
	req.SetPathValue("guid", "chat-guid")
	rec := httptest.NewRecorder()

	handlers.SendText(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d", rec.Code)
	}
	if pending.Has("one") {
		t.Fatal("expected pending tempGuid to be removed after failure")
	}
}

func TestSendTextConfirmsWhenMatchFound(t *testing.T) {
	matchGUID := "msg-123"
	text := "hello world"
	queries := &stubQueries{match: &store.MessageJSON{GUID: matchGUID, Text: &text}}
	pending := &fakePendingManager{}
	handlers := NewHandlers(queries, log.New(io.Discard, "", 0), &SendDependencies{
		Pending: pending,
		Sender:  noopSender{},
	}, nil, "", &stubDeviceStore{}, stubNotifier{}, config.Config{HTTPAddr: "127.0.0.1:3000"}, StatusDeps{})

	req := httptest.NewRequest(http.MethodPost, "/api/chats/chat-guid/send", strings.NewReader(`{"tempGuid":"ok","message":"hello world"}`))
	req.SetPathValue("guid", "chat-guid")
	rec := httptest.NewRecorder()

	handlers.SendText(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d (%s)", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), matchGUID) {
		t.Fatalf("expected matched message in body, got %s", rec.Body.String())
	}
	if owner := pending.claimed[matchGUID]; owner != "ok" {
		t.Fatalf("expected matched row claimed by 'ok', got %q", owner)
	}
	if pending.Has("ok") {
		t.Fatal("expected pending tempGuid removed after confirmation")
	}
}

type stubAttachmentStore struct {
	meta *store.AttachmentMeta
	err  error
}

func (s stubAttachmentStore) GetAttachmentByGUID(context.Context, string) (*store.AttachmentMeta, error) {
	return s.meta, s.err
}

func TestResolveAttachmentPathRejectsOutsideRoot(t *testing.T) {
	root := t.TempDir()
	outside := filepath.Join(t.TempDir(), "outside.txt")
	if err := os.WriteFile(outside, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, ok := resolveAttachmentPath(root, &outside); ok {
		t.Fatal("expected path outside root to be rejected")
	}
}

func TestGetAttachmentNotFoundWhenHidden(t *testing.T) {
	root := t.TempDir()
	meta := &store.AttachmentMeta{
		GUID:           "att-1",
		HideAttachment: true,
	}
	handlers := NewHandlers(&stubQueries{}, log.New(io.Discard, "", 0), nil, stubAttachmentStore{meta: meta}, root, &stubDeviceStore{}, stubNotifier{}, config.Config{HTTPAddr: "127.0.0.1:3000"}, StatusDeps{})

	req := httptest.NewRequest(http.MethodGet, "/api/attachments/att-1", nil)
	req.SetPathValue("guid", "att-1")
	rec := httptest.NewRecorder()

	handlers.GetAttachment(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", rec.Code)
	}
}

func TestGetAttachmentStreamsFile(t *testing.T) {
	root := t.TempDir()
	filePath := filepath.Join(root, "folder", "file.txt")
	if err := os.MkdirAll(filepath.Dir(filePath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filePath, []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}

	home := t.TempDir()
	t.Setenv("HOME", home)
	localPath := filePath
	meta := &store.AttachmentMeta{
		GUID:         "att-1",
		LocalPath:    &localPath,
		TransferName: ptr("file.txt"),
		MimeType:     ptr("text/plain"),
	}

	handlers := NewHandlers(&stubQueries{}, log.New(io.Discard, "", 0), nil, stubAttachmentStore{meta: meta}, root, &stubDeviceStore{}, stubNotifier{}, config.Config{HTTPAddr: "127.0.0.1:3000"}, StatusDeps{})
	req := httptest.NewRequest(http.MethodGet, "/api/attachments/att-1", nil)
	req.SetPathValue("guid", "att-1")
	rec := httptest.NewRecorder()

	handlers.GetAttachment(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	if got := rec.Body.String(); got != "hello" {
		t.Fatalf("expected file contents, got %q", got)
	}
}

func TestAttachmentPreviewConversionScope(t *testing.T) {
	// HEIC/TIFF can't be decoded by the Flutter client; JPEG is decodable but its
	// EXIF orientation was rendering sideways — both are rasterized to an
	// orientation-correct PNG by the server's Quick Look preview (C48). PNG is
	// web-renderable and carries no EXIF orientation, so it is served directly.
	convert := []store.AttachmentMeta{
		{MimeType: ptr("image/heic")},
		{Uti: ptr("public.heif")},
		{TransferName: ptr("scan.tiff")},
		{MimeType: ptr("image/jpeg")},
		{Uti: ptr("public.jpeg")},
		{TransferName: ptr("portrait.jpg")},
		{Filename: ptr("/tmp/portrait.jpeg")},
	}
	for _, tc := range convert {
		if !attachmentNeedsPreviewConversion(&tc) {
			t.Fatalf("expected metadata to need preview conversion: %+v", tc)
		}
	}

	png := &store.AttachmentMeta{MimeType: ptr("image/png"), TransferName: ptr("image.png")}
	if attachmentNeedsPreviewConversion(png) {
		t.Fatal("PNG should still be served directly")
	}
}

func TestRegisterListAndDeleteDevice(t *testing.T) {
	devices := &stubDeviceStore{}
	handlers := NewHandlers(&stubQueries{}, log.New(io.Discard, "", 0), nil, nil, "", devices, stubNotifier{}, config.Config{HTTPAddr: "127.0.0.1:3000"}, StatusDeps{})

	registerReq := httptest.NewRequest(http.MethodPost, "/api/devices/register", strings.NewReader(`{"name":"Cinmou Android","platform":"android","clientType":"flutter","pushProvider":"none","pushEnabled":false}`))
	registerRec := httptest.NewRecorder()
	handlers.RegisterDevice(registerRec, registerReq)

	if registerRec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", registerRec.Code)
	}
	var registered store.DeviceResponse
	if err := json.Unmarshal(registerRec.Body.Bytes(), &registered); err != nil {
		t.Fatal(err)
	}
	if registered.Data.ID == "" {
		t.Fatal("expected generated device id")
	}
	if registered.Data.PushTokenSet {
		t.Fatal("expected push token to be hidden/unset")
	}

	listReq := httptest.NewRequest(http.MethodGet, "/api/devices", nil)
	listRec := httptest.NewRecorder()
	handlers.ListDevices(listRec, listReq)
	if listRec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", listRec.Code)
	}
	if !strings.Contains(listRec.Body.String(), "Cinmou Android") {
		t.Fatalf("unexpected list body: %s", listRec.Body.String())
	}

	deleteReq := httptest.NewRequest(http.MethodDelete, "/api/devices/"+registered.Data.ID, nil)
	deleteReq.SetPathValue("id", registered.Data.ID)
	deleteRec := httptest.NewRecorder()
	handlers.DeleteDevice(deleteRec, deleteReq)
	if deleteRec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", deleteRec.Code)
	}
}

func TestRegisterDeviceRejectsInvalidPlatform(t *testing.T) {
	handlers := NewHandlers(&stubQueries{}, log.New(io.Discard, "", 0), nil, nil, "", &stubDeviceStore{}, stubNotifier{}, config.Config{HTTPAddr: "127.0.0.1:3000"}, StatusDeps{})
	req := httptest.NewRequest(http.MethodPost, "/api/devices/register", strings.NewReader(`{"name":"Bad","platform":"beos","clientType":"flutter","pushProvider":"none","pushEnabled":false}`))
	rec := httptest.NewRecorder()

	handlers.RegisterDevice(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestTestNotificationsRequiresRegisteredDevice(t *testing.T) {
	handlers := NewHandlers(&stubQueries{}, log.New(io.Discard, "", 0), nil, nil, "", &stubDeviceStore{}, stubNotifier{}, config.Config{HTTPAddr: "127.0.0.1:3000"}, StatusDeps{})
	req := httptest.NewRequest(http.MethodPost, "/api/server/notifications/test", nil)
	rec := httptest.NewRecorder()

	handlers.TestNotifications(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "push_no_devices") {
		t.Fatalf("unexpected body: %s", rec.Body.String())
	}
}

func TestTestNotificationsSendsToFcmDevices(t *testing.T) {
	pushToken := "tok-123"
	devices := &stubDeviceStore{
		devices: map[string]store.DeviceRecord{
			"fcm-1": {ID: "fcm-1", Name: "Pixel", Platform: "android", ClientType: "flutter", PushProvider: "fcm", PushToken: &pushToken, PushEnabled: true, CreatedAt: 1, UpdatedAt: 1},
			"ws-1":  {ID: "ws-1", Name: "LAN only", Platform: "android", ClientType: "flutter", PushProvider: "none", PushEnabled: false, CreatedAt: 1, UpdatedAt: 1},
		},
	}
	sent := 0
	handlers := NewHandlers(&stubQueries{}, log.New(io.Discard, "", 0), nil, nil, "", devices, stubNotifier{sent: &sent}, config.Config{HTTPAddr: "127.0.0.1:3000"}, StatusDeps{})
	req := httptest.NewRequest(http.MethodPost, "/api/server/notifications/test", nil)
	rec := httptest.NewRecorder()

	handlers.TestNotifications(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	if sent != 1 {
		t.Fatalf("expected one FCM send, got %d", sent)
	}
	if !strings.Contains(rec.Body.String(), `"sent":1`) {
		t.Fatalf("unexpected body: %s", rec.Body.String())
	}
}

func ptr[T any](v T) *T { return &v }

func TestGetServerStatus(t *testing.T) {
	devices := &stubDeviceStore{devices: map[string]store.DeviceRecord{
		"d1": {ID: "d1", Name: "One"},
		"d2": {ID: "d2", Name: "Two"},
	}}
	syncState := map[string]string{
		"last_sync_at":       "1717372800000",
		"last_message_rowid": "4242",
	}
	handlers := NewHandlers(
		&stubQueries{}, log.New(io.Discard, "", 0), nil, nil, "", devices, stubNotifier{},
		config.Config{
			HTTPAddr:             "127.0.0.1:3000",
			AuthDisabled:         false,
			DisableSyncLoop:      false,
			SyncInterval:         5 * time.Second,
			NotificationsEnabled: true,
			NotificationProvider: "webhook",
			NotificationPreview:  "sender",
		},
		StatusDeps{
			APIStore:    "relaydb",
			ClientCount: func() int { return 3 },
			SyncState: func(key string) (string, bool, error) {
				v, ok := syncState[key]
				return v, ok, nil
			},
		},
	)

	req := httptest.NewRequest(http.MethodGet, "/api/server/status", nil)
	rec := httptest.NewRecorder()
	handlers.GetServerStatus(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}

	var status store.ServerStatusResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &status); err != nil {
		t.Fatalf("decode status: %v", err)
	}

	if !status.OK {
		t.Fatalf("expected ok=true")
	}
	if status.Version != version.Version {
		t.Fatalf("expected version %q, got %q", version.Version, status.Version)
	}
	if status.Store != "relaydb" {
		t.Fatalf("expected store relaydb, got %q", status.Store)
	}
	if !status.Auth.Enabled {
		t.Fatalf("expected auth enabled")
	}
	if !status.Sync.LoopEnabled || status.Sync.IntervalSeconds != 5 {
		t.Fatalf("unexpected sync status: %+v", status.Sync)
	}
	if status.Sync.LastSyncAt == nil || *status.Sync.LastSyncAt != 1717372800000 {
		t.Fatalf("unexpected lastSyncAt: %+v", status.Sync.LastSyncAt)
	}
	if status.Sync.LastMessageRowID == nil || *status.Sync.LastMessageRowID != 4242 {
		t.Fatalf("unexpected lastMessageRowId: %+v", status.Sync.LastMessageRowID)
	}
	if status.Devices.Count != 2 {
		t.Fatalf("expected 2 devices, got %d", status.Devices.Count)
	}
	if status.WebSocket.Clients != 3 {
		t.Fatalf("expected 3 ws clients, got %d", status.WebSocket.Clients)
	}
	// Notification status is sourced from the dispatcher (stubNotifier here):
	// enabled=true, provider="none", preview="sender".
	if !status.Notifications.Enabled || status.Notifications.Provider != "none" {
		t.Fatalf("unexpected notifications: %+v", status.Notifications)
	}
	if !contains(status.Notifications.Implemented, "webhook") || !contains(status.Notifications.Implemented, "none") {
		t.Fatalf("expected none+webhook implemented, got %v", status.Notifications.Implemented)
	}
	if !contains(status.Notifications.Stub, "fcm") {
		t.Fatalf("expected fcm in stub list, got %v", status.Notifications.Stub)
	}
	if status.Permissions.Automation.Status != "unknown" {
		t.Fatalf("expected automation unknown, got %q", status.Permissions.Automation.Status)
	}
}

func TestGetServerConnections(t *testing.T) {
	handlers := NewHandlers(
		&stubQueries{}, log.New(io.Discard, "", 0), nil, nil, "", &stubDeviceStore{}, stubNotifier{},
		config.Config{HTTPAddr: "127.0.0.1:3000"},
		StatusDeps{
			Connections: func() []realtime.ClientSession {
				return []realtime.ClientSession{{
					ID:          "ws_1",
					ClientName:  "Pixel",
					ClientType:  "flutter",
					Platform:    "android",
					AppVersion:  "1.2.3",
					ConnectedAt: 1717372800000,
					LastSeenAt:  1717372801000,
				}}
			},
		},
	)

	req := httptest.NewRequest(http.MethodGet, "/api/server/connections", nil)
	rec := httptest.NewRecorder()
	handlers.GetServerConnections(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	var payload struct {
		Data []realtime.ClientSession `json:"data"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode connections: %v", err)
	}
	if len(payload.Data) != 1 || payload.Data[0].ID != "ws_1" {
		t.Fatalf("unexpected connections payload: %+v", payload)
	}
}

func TestGetServerStatusTokenNeverExposed(t *testing.T) {
	handlers := NewHandlers(
		&stubQueries{}, log.New(io.Discard, "", 0), nil, nil, "", &stubDeviceStore{}, stubNotifier{},
		config.Config{HTTPAddr: "127.0.0.1:3000", AuthToken: "super-secret-token"},
		StatusDeps{APIStore: "relaydb"},
	)
	req := httptest.NewRequest(http.MethodGet, "/api/server/status", nil)
	rec := httptest.NewRecorder()
	handlers.GetServerStatus(rec, req)

	if strings.Contains(rec.Body.String(), "super-secret-token") {
		t.Fatalf("status response leaked the auth token: %s", rec.Body.String())
	}
}

type stubErrorFinder struct {
	code  int64
	found bool
	calls int
}

func (s *stubErrorFinder) FindOutgoingMessageError(_ context.Context, _ string, _ string, _ int64) (int64, bool, error) {
	s.calls++
	return s.code, s.found, nil
}

func TestSendTextFailsFastWhenMessagesNotRunning(t *testing.T) {
	// errorSender would yield send_failed if reached; the precondition must
	// short-circuit before the sender is invoked.
	handlers := NewHandlers(
		&stubQueries{}, log.New(io.Discard, "", 0),
		&SendDependencies{
			Pending:         &fakePendingManager{},
			Sender:          errorSender{},
			MessagesRunning: func(context.Context) (bool, error) { return false, nil },
		},
		nil, "", &stubDeviceStore{}, stubNotifier{},
		config.Config{HTTPAddr: "127.0.0.1:3000"},
		StatusDeps{},
	)

	req := httptest.NewRequest(http.MethodPost, "/api/chats/chat-1/send",
		strings.NewReader(`{"tempGuid":"t1","message":"hello"}`))
	req.SetPathValue("guid", "chat-1")
	rec := httptest.NewRecorder()
	handlers.SendText(rec, req)

	if rec.Code != http.StatusConflict {
		t.Fatalf("expected 409, got %d (body: %s)", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "messages_app_not_running") {
		t.Fatalf("expected messages_app_not_running, got: %s", rec.Body.String())
	}
}

func TestSendTextProbeErrorDoesNotBlockSend(t *testing.T) {
	// If the probe itself errors, the send should proceed (here the sender then
	// fails, yielding send_failed — proving we did NOT block on the probe error).
	handlers := NewHandlers(
		&stubQueries{}, log.New(io.Discard, "", 0),
		&SendDependencies{
			Pending:         &fakePendingManager{},
			Sender:          errorSender{},
			MessagesRunning: func(context.Context) (bool, error) { return false, errors.New("pgrep missing") },
		},
		nil, "", &stubDeviceStore{}, stubNotifier{},
		config.Config{HTTPAddr: "127.0.0.1:3000"},
		StatusDeps{},
	)

	req := httptest.NewRequest(http.MethodPost, "/api/chats/chat-1/send",
		strings.NewReader(`{"tempGuid":"t1","message":"hello"}`))
	req.SetPathValue("guid", "chat-1")
	rec := httptest.NewRecorder()
	handlers.SendText(rec, req)

	if !strings.Contains(rec.Body.String(), "send_failed") {
		t.Fatalf("probe error must not block send; expected send_failed, got: %s", rec.Body.String())
	}
}

func TestSendTextFastFailsOnMessageError(t *testing.T) {
	finder := &stubErrorFinder{code: 22, found: true}
	handlers := NewHandlers(
		&stubQueries{}, log.New(io.Discard, "", 0),
		&SendDependencies{Pending: &fakePendingManager{}, Sender: noopSender{}, ErrorFinder: finder},
		nil, "", &stubDeviceStore{}, stubNotifier{},
		config.Config{HTTPAddr: "127.0.0.1:3000"},
		StatusDeps{Capabilities: store.SchemaCapabilities{SendError: true}},
	)

	req := httptest.NewRequest(http.MethodPost, "/api/chats/chat-1/send",
		strings.NewReader(`{"tempGuid":"t1","message":"hello"}`))
	req.SetPathValue("guid", "chat-1")
	rec := httptest.NewRecorder()
	handlers.SendText(rec, req)

	if rec.Code != http.StatusBadGateway {
		t.Fatalf("expected 502, got %d (body: %s)", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	if !strings.Contains(body, "send_error") || !strings.Contains(body, "error 22") {
		t.Fatalf("expected send_error with code 22, got: %s", body)
	}
	if finder.calls == 0 {
		t.Fatalf("error finder should have been consulted")
	}
}

func TestSendTextSkipsErrorCheckWhenCapabilityOff(t *testing.T) {
	finder := &stubErrorFinder{code: 22, found: true}
	handlers := NewHandlers(
		&stubQueries{}, log.New(io.Discard, "", 0),
		&SendDependencies{Pending: &fakePendingManager{}, Sender: noopSender{}, ErrorFinder: finder},
		nil, "", &stubDeviceStore{}, stubNotifier{},
		config.Config{HTTPAddr: "127.0.0.1:3000"},
		StatusDeps{Capabilities: store.SchemaCapabilities{SendError: false}},
	)

	// Short context so the wait loop exits quickly via cancellation instead of
	// the 120s timeout.
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	req := httptest.NewRequest(http.MethodPost, "/api/chats/chat-1/send",
		strings.NewReader(`{"tempGuid":"t2","message":"hello"}`)).WithContext(ctx)
	req.SetPathValue("guid", "chat-1")
	rec := httptest.NewRecorder()
	handlers.SendText(rec, req)

	if finder.calls != 0 {
		t.Fatalf("error finder must NOT be called when SendError capability is off, got %d calls", finder.calls)
	}
	if !strings.Contains(rec.Body.String(), "send_failed") {
		t.Fatalf("expected send_failed (canceled), got: %s", rec.Body.String())
	}
}

func TestGetServerStatusIncludesCapabilities(t *testing.T) {
	caps := store.SchemaCapabilities{
		EditedMessages:  true,
		ReadStatus:      true,
		DeliveredStatus: true,
		// UnsentMessages, SendError, GroupActions, AttachmentMetadata left false
	}
	handlers := NewHandlers(
		&stubQueries{}, log.New(io.Discard, "", 0), nil, nil, "", &stubDeviceStore{}, stubNotifier{},
		config.Config{HTTPAddr: "127.0.0.1:3000"},
		StatusDeps{APIStore: "relaydb", Capabilities: caps},
	)
	req := httptest.NewRequest(http.MethodGet, "/api/server/status", nil)
	rec := httptest.NewRecorder()
	handlers.GetServerStatus(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	var status store.ServerStatusResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &status); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if status.Capabilities.Schema != caps {
		t.Fatalf("capabilities not surfaced: got %+v, want %+v", status.Capabilities.Schema, caps)
	}
}

type stubRuleService struct {
	rules      []store.SyncRuleJSON
	syncPolicy string
	pushPolicy string
}

func (s *stubRuleService) ListSyncRules(_ context.Context) ([]store.SyncRuleJSON, error) {
	return s.rules, nil
}
func (s *stubRuleService) UpsertSyncRule(_ context.Context, rule store.SyncRuleJSON) error {
	s.rules = append(s.rules, rule)
	return nil
}
func (s *stubRuleService) DeleteSyncRule(_ context.Context, _, _ string) error { return nil }
func (s *stubRuleService) DefaultPolicies(_ context.Context) (string, string, error) {
	sp := s.syncPolicy
	if sp == "" {
		sp = "allow_all"
	}
	pp := s.pushPolicy
	if pp == "" {
		pp = "enabled"
	}
	return sp, pp, nil
}
func (s *stubRuleService) SetDefaultPolicies(_ context.Context, sync, push string) error {
	s.syncPolicy, s.pushPolicy = sync, push
	return nil
}

func newRuleHandlers(rs ruleService) *Handlers {
	h := NewHandlers(&stubQueries{}, log.New(io.Discard, "", 0), nil, nil, "", &stubDeviceStore{}, stubNotifier{},
		config.Config{HTTPAddr: "127.0.0.1:3000"}, StatusDeps{})
	h.SetRuleService(rs)
	return h
}

func TestPutAndGetSyncRules(t *testing.T) {
	h := newRuleHandlers(&stubRuleService{})

	put := httptest.NewRequest(http.MethodPut, "/api/sync/rules",
		strings.NewReader(`{"targetKind":"chat","targetValue":"iMessage;-;+1555","syncMode":"block","pushMode":"inherit"}`))
	rec := httptest.NewRecorder()
	h.PutSyncRule(rec, put)
	if rec.Code != http.StatusOK {
		t.Fatalf("PUT rule expected 200, got %d (%s)", rec.Code, rec.Body.String())
	}

	get := httptest.NewRequest(http.MethodGet, "/api/sync/rules", nil)
	grec := httptest.NewRecorder()
	h.GetSyncRules(grec, get)
	var resp store.SyncRulesResponse
	if err := json.Unmarshal(grec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.DefaultSyncPolicy != "allow_all" || len(resp.Rules) != 1 || resp.Rules[0].SyncMode != "block" {
		t.Fatalf("unexpected rules response: %+v", resp)
	}
}

func TestPutSyncRuleRejectsInvalidKind(t *testing.T) {
	h := newRuleHandlers(&stubRuleService{})
	req := httptest.NewRequest(http.MethodPut, "/api/sync/rules",
		strings.NewReader(`{"targetKind":"group","targetValue":"x","syncMode":"block","pushMode":"inherit"}`))
	rec := httptest.NewRecorder()
	h.PutSyncRule(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for invalid targetKind, got %d", rec.Code)
	}
}

func TestSyncRulesUnavailableWhenUnset(t *testing.T) {
	h := NewHandlers(&stubQueries{}, log.New(io.Discard, "", 0), nil, nil, "", &stubDeviceStore{}, stubNotifier{},
		config.Config{HTTPAddr: "127.0.0.1:3000"}, StatusDeps{})
	rec := httptest.NewRecorder()
	h.GetSyncRules(rec, httptest.NewRequest(http.MethodGet, "/api/sync/rules", nil))
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500 when rule service unset, got %d", rec.Code)
	}
}

// C21u: connection state is derived from last-seen freshness (heartbeat), and
// the device JSON carries app version + mode for the Companion card.
func TestDeviceConnectedDerivation(t *testing.T) {
	now := time.Now().UnixMilli()
	fresh := now - 10_000  // 10s ago → connected
	stale := now - 600_000 // 10min ago → disconnected

	if !deviceConnected(&fresh) {
		t.Fatal("a device seen 10s ago should be connected")
	}
	if deviceConnected(&stale) {
		t.Fatal("a device seen 10min ago should be disconnected")
	}
	if deviceConnected(nil) {
		t.Fatal("a device that never checked in should be disconnected")
	}

	js := deviceToJSON(store.DeviceRecord{
		ID: "d1", Name: "Pixel", Platform: "android", ClientType: "flutter",
		AppVersion: "0.1.0", Mode: "lan_public", PushProvider: "none",
		LastSeenAt: &fresh,
	})
	if js.AppVersion != "0.1.0" || js.Mode != "lan_public" || !js.Connected {
		t.Fatalf("unexpected device JSON: %#v", js)
	}
}

func contains(items []string, want string) bool {
	for _, item := range items {
		if item == want {
			return true
		}
	}
	return false
}

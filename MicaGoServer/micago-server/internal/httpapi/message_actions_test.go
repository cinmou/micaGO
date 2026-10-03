package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"testing"

	"micagoserver/internal/config"
	"micagoserver/internal/imessage"
	"micagoserver/internal/store"
)

type stubMessageActions struct {
	caps        imessage.Capabilities
	invalidated int
	editReq     imessage.Request
	retractReq  imessage.Request
	deleteReq   imessage.Request
	err         error
}

// invalidated counts InvalidateCapabilities calls; when >0 the stub flips to a
// "ready" capability set, simulating a freshly-installed helper.
func (s *stubMessageActions) Capabilities(context.Context) imessage.Capabilities {
	if s.invalidated > 0 {
		return imessage.Capabilities{Available: true, State: imessage.HelperStateReady, Edit: true, Retract: true, Delete: true, RequiresMessages: true}
	}
	return s.caps
}
func (s *stubMessageActions) InvalidateCapabilities() { s.invalidated++ }
func (s *stubMessageActions) Edit(_ context.Context, req imessage.Request) error {
	s.editReq = req
	return s.err
}
func (s *stubMessageActions) Retract(_ context.Context, req imessage.Request) error {
	s.retractReq = req
	return s.err
}
func (s *stubMessageActions) Delete(_ context.Context, req imessage.Request) error {
	s.deleteReq = req
	return s.err
}

func newActionHandlers(actions imessage.Performer) (*Handlers, *int) {
	syncs := 0
	h := NewHandlers(&stubQueries{}, log.New(io.Discard, "", 0), nil, nil, "", &stubDeviceStore{}, stubNotifier{},
		config.Config{HTTPAddr: "127.0.0.1:3000"}, StatusDeps{})
	h.SetMessageActionPerformer(actions)
	h.SetSyncNow(func(context.Context) (store.ServerSyncDiagnostics, error) {
		syncs++
		return store.ServerSyncDiagnostics{}, nil
	})
	return h, &syncs
}

func TestMessageActionCapabilitiesUnsupportedWithoutHelper(t *testing.T) {
	h, _ := newActionHandlers(nil)
	req := httptest.NewRequest(http.MethodGet, "/api/messages/actions/capabilities", nil)
	rec := httptest.NewRecorder()
	h.GetMessageActionCapabilities(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	var caps imessage.Capabilities
	if err := json.Unmarshal(rec.Body.Bytes(), &caps); err != nil {
		t.Fatal(err)
	}
	if caps.Available || caps.Edit || caps.Retract || caps.Delete {
		t.Fatalf("expected unavailable caps, got %+v", caps)
	}
}

// The refresh endpoint must invalidate the cache and return the freshly-probed
// (now "ready") capabilities — the install→rescan chain.
func TestRefreshMessageActionCapabilities(t *testing.T) {
	actions := &stubMessageActions{caps: imessage.Capabilities{Available: false, State: imessage.HelperStateMissing}}
	h, _ := newActionHandlers(actions)

	// Before refresh: missing.
	if c := h.messageActionCapabilities(context.Background()); c.Available {
		t.Fatal("expected unavailable before refresh")
	}

	req := httptest.NewRequest(http.MethodPost, "/api/messages/actions/refresh", nil)
	rec := httptest.NewRecorder()
	h.RefreshMessageActionCapabilities(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	if actions.invalidated != 1 {
		t.Fatalf("expected cache invalidation, got %d", actions.invalidated)
	}
	var caps imessage.Capabilities
	if err := json.Unmarshal(rec.Body.Bytes(), &caps); err != nil {
		t.Fatal(err)
	}
	if !caps.Available || caps.State != imessage.HelperStateReady {
		t.Fatalf("expected ready after refresh, got %+v", caps)
	}
}

func TestEditMessageActionSuccess(t *testing.T) {
	actions := &stubMessageActions{}
	h, syncs := newActionHandlers(actions)
	body := bytes.NewBufferString(`{"text":"updated","partIndex":2}`)
	req := httptest.NewRequest(http.MethodPost, "/api/chats/chat-1/messages/msg-1/edit", body)
	req.SetPathValue("guid", "chat-1")
	req.SetPathValue("messageGuid", "msg-1")
	rec := httptest.NewRecorder()

	h.EditMessage(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", rec.Code, rec.Body.String())
	}
	if actions.editReq.ChatGUID != "chat-1" || actions.editReq.MessageGUID != "msg-1" || actions.editReq.Text != "updated" || actions.editReq.PartIndex != 2 {
		t.Fatalf("unexpected edit req: %+v", actions.editReq)
	}
	if *syncs != 1 {
		t.Fatalf("expected sync after edit, got %d", *syncs)
	}
}

func TestRetractMessageActionMapsExpired(t *testing.T) {
	actions := &stubMessageActions{err: &imessage.ActionError{Code: "expired", Message: "edit window expired", StatusCode: http.StatusConflict}}
	h, _ := newActionHandlers(actions)
	req := httptest.NewRequest(http.MethodPost, "/api/chats/chat-1/messages/msg-1/retract", bytes.NewBufferString(`{}`))
	req.SetPathValue("guid", "chat-1")
	req.SetPathValue("messageGuid", "msg-1")
	rec := httptest.NewRecorder()

	h.RetractMessage(rec, req)

	if rec.Code != http.StatusConflict {
		t.Fatalf("expected 409, got %d", rec.Code)
	}
	if !bytes.Contains(rec.Body.Bytes(), []byte(`"code":"expired"`)) {
		t.Fatalf("expected expired code, got %s", rec.Body.String())
	}
}

func TestDeleteMessageActionSuccess(t *testing.T) {
	actions := &stubMessageActions{}
	h, syncs := newActionHandlers(actions)
	req := httptest.NewRequest(http.MethodDelete, "/api/chats/chat-1/messages/msg-1", nil)
	req.SetPathValue("guid", "chat-1")
	req.SetPathValue("messageGuid", "msg-1")
	rec := httptest.NewRecorder()

	h.DeleteMessage(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	if actions.deleteReq.ChatGUID != "chat-1" || actions.deleteReq.MessageGUID != "msg-1" {
		t.Fatalf("unexpected delete req: %+v", actions.deleteReq)
	}
	if *syncs != 1 {
		t.Fatalf("expected sync after delete, got %d", *syncs)
	}
}

func TestHelperPerformerUnsupportedWhenHelperMissing(t *testing.T) {
	p := imessage.NewHelperPerformer("")
	p.Lookup = func() (string, error) { return "", errors.New("missing bundled helper") }
	err := p.Delete(context.Background(), imessage.Request{ChatGUID: "chat", MessageGUID: "msg"})
	if imessage.ErrorCode(err) != "unsupported" || imessage.ErrorStatus(err) != http.StatusNotImplemented {
		t.Fatalf("expected unsupported/501, got code=%s status=%d err=%v", imessage.ErrorCode(err), imessage.ErrorStatus(err), err)
	}
}

func TestRetractRejectsMalformedOrAmbiguousBody(t *testing.T) {
	for _, body := range []string{`{"partIndex":`, `{"partIndex":-1}`, `{"partIndex":1} {}`, `{"unknown":1}`} {
		actions := &stubMessageActions{}
		h, syncs := newActionHandlers(actions)
		r := httptest.NewRequest(http.MethodPost, "/retract", bytes.NewBufferString(body))
		r.SetPathValue("guid", "chat-1")
		r.SetPathValue("messageGuid", "msg-1")
		w := httptest.NewRecorder()
		h.RetractMessage(w, r)
		if w.Code != 400 || actions.retractReq.MessageGUID != "" || *syncs != 0 {
			t.Fatalf("malformed body triggered action: %s status=%d", body, w.Code)
		}
	}
}

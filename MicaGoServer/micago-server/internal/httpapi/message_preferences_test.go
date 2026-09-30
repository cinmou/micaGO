package httpapi

import (
	"encoding/json"
	"io"
	"log"
	"micagoserver/internal/config"
	"micagoserver/internal/relaydb"
	"micagoserver/internal/store"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
)

func TestMessagePreferenceHTTPContract(t *testing.T) {
	db, err := relaydb.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	h := NewHandlers(&stubQueries{}, log.New(io.Discard, "", 0), nil, nil, "", &stubDeviceStore{}, stubNotifier{}, config.Config{}, StatusDeps{})
	h.SetMessagePreferences(db, nil)
	router := NewRouter(h, nil, AuthConfig{Enabled: true, Token: "test-token"})
	call := func(method, path, body string, auth bool) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, strings.NewReader(body))
		if auth {
			r.Header.Set("Authorization", "Bearer test-token")
		}
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		return w
	}
	for _, method := range []string{http.MethodGet, http.MethodPatch} {
		if got := call(method, "/api/message-preferences", "{}", false); got.Code != 401 {
			t.Fatalf("unauthenticated %s: %d", method, got.Code)
		}
	}
	initial := call(http.MethodGet, "/api/message-preferences", "", true)
	var state store.MessagePreferences
	if initial.Code != 200 {
		t.Fatalf("snapshot: %d", initial.Code)
	}
	if err := json.Unmarshal(initial.Body.Bytes(), &state); err != nil {
		t.Fatal(err)
	}
	prefix := `{"serverId":"` + state.ServerID + `","mutationId":"test-operation","changes":`
	for _, changes := range []string{
		`[]}`, `[{"messageKey":"raw-guid","hidden":true,"baseRevision":0}]}`, `[{"messageKey":"route\u001fa","baseRevision":0}]}`, `[{"messageKey":"route\u001fa","hidden":true}]}`,
		`[{"messageKey":"route\u001fa","hidden":null,"baseRevision":0}]}`, `[{"messageKey":"route\u001fa","hidden":true,"baseRevision":-1}]}`,
		`[{"messageKey":"route\u001fa","hidden":true,"baseRevision":0},{"messageKey":"route\u001fa","hidden":false,"baseRevision":0}]}`,
		`[{"messageKey":"route\u001fa","hidden":true,"baseRevision":0,"extra":1}]}`,
	} {
		if got := call(http.MethodPatch, "/api/message-preferences", prefix+changes, true); got.Code != 400 {
			t.Fatalf("invalid payload returned %d: %s", got.Code, changes)
		}
	}
	body := prefix + `[{"messageKey":"route\u001fa","hidden":true,"baseRevision":0}]}`
	if got := call(http.MethodPatch, "/api/message-preferences", body, true); got.Code != 200 {
		t.Fatalf("patch: %d %s", got.Code, got.Body.String())
	}
	stale := strings.Replace(body, "test-operation", "stale-operation", 1)
	if got := call(http.MethodPatch, "/api/message-preferences", stale, true); got.Code != 409 || !strings.Contains(got.Body.String(), "preference_conflict") {
		t.Fatalf("conflict: %d %s", got.Code, got.Body.String())
	}
	if got := call(http.MethodGet, "/api/message-preferences?since=1", "", true); got.Code != 200 || !strings.Contains(got.Body.String(), `"data":[]`) {
		t.Fatalf("delta: %s", got.Body.String())
	}
	for _, cursor := range []string{"-1", "invalid"} {
		if got := call(http.MethodGet, "/api/message-preferences?since="+cursor, "", true); got.Code != 400 {
			t.Fatal("invalid cursor accepted")
		}
	}
	if got := call(http.MethodGet, "/api/message-preferences?since=2", "", true); got.Code != 409 {
		t.Fatal("future cursor accepted")
	}
}

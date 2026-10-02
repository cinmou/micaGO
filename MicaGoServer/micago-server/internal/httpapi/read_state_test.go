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

func TestReadStateHTTPContract(t *testing.T) {
	db, err := relaydb.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	h := NewHandlers(&stubQueries{}, log.New(io.Discard, "", 0), nil, nil, "", &stubDeviceStore{}, stubNotifier{}, config.Config{}, StatusDeps{})
	h.SetReadState(db, nil)
	router := NewRouter(h, nil, AuthConfig{Enabled: true, Token: "test-token"})
	call := func(method, body string, auth bool) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "/api/read-state", strings.NewReader(body))
		if auth {
			r.Header.Set("Authorization", "Bearer test-token")
		}
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		return w
	}
	for _, method := range []string{http.MethodGet, http.MethodPatch} {
		if call(method, "{}", false).Code != 401 {
			t.Fatal("unauthenticated read state")
		}
	}
	var initial store.ReadState
	if err = json.Unmarshal(call(http.MethodGet, "", true).Body.Bytes(), &initial); err != nil {
		t.Fatal(err)
	}
	prefix := `{"serverId":"` + initial.ServerID + `","changes":`
	for _, body := range []string{`[]}`, `[{"chatGuid":"","readThrough":1}]}`, `[{"chatGuid":"a","readThrough":0}]}`, `[{"chatGuid":"a","readThrough":-1}]}`, `[{"chatGuid":"a","readThrough":1},{"chatGuid":"a","readThrough":2}]}`, `[{"chatGuid":"a","readThrough":1,"extra":true}]}`} {
		if call(http.MethodPatch, prefix+body, true).Code != 400 {
			t.Fatal("invalid position accepted")
		}
	}
	if call(http.MethodPatch, prefix+`[{"chatGuid":"a","readThrough":200}]}`, true).Code != 200 {
		t.Fatal("valid read failed")
	}
	if call(http.MethodPatch, strings.ReplaceAll(prefix, initial.ServerID, strings.Repeat("b", 32))+`[{"chatGuid":"a","readThrough":200}]}`, true).Code != 409 {
		t.Fatal("foreign server accepted")
	}
}

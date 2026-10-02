package httpapi

import (
	"context"
	"encoding/json"
	"micagoserver/internal/config"
	"micagoserver/internal/relaydb"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
)

func TestPairingVisibilityPersistsAndChangesEndpointRevision(t *testing.T) {
	path := filepath.Join(t.TempDir(), "relay.db")
	db, err := relaydb.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	h := newURLHandlers("192.168.4.2:3000", NewNetworkController(config.Config{}))
	h.SetLANVisibility(db, nil)
	router := NewRouter(h, nil, AuthConfig{Enabled: true, Token: "test-token"})
	call := func(body string, auth bool) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodPut, "/api/server/lan-visibility", strings.NewReader(body))
		if auth {
			r.Header.Set("Authorization", "Bearer test-token")
		}
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		return w
	}
	if call(`{"hiddenBaseUrls":[]}`, false).Code != 401 {
		t.Fatal("unauthenticated update")
	}
	before := h.buildServerURLs()
	if len(before.LAN) != 1 || before.LAN[0].Hidden != nil {
		t.Fatal("legacy visibility became authoritative")
	}
	for _, body := range []string{`{}`, `{"hiddenBaseUrls":["invalid"]}`, `{"hiddenBaseUrls":[]} {}`} {
		if call(body, true).Code != 400 {
			t.Fatal("invalid visibility accepted")
		}
	}
	response := call(`{"hiddenBaseUrls":["http://192.168.4.2:3000"]}`, true)
	var hidden ServerURLsResponse
	if response.Code != 200 {
		t.Fatal(response.Code)
	}
	if err = json.Unmarshal(response.Body.Bytes(), &hidden); err != nil {
		t.Fatal(err)
	}
	if hidden.ConnectionRevision == before.ConnectionRevision || hidden.LAN[0].Hidden == nil || !*hidden.LAN[0].Hidden {
		t.Fatal("hidden setting not published")
	}
	db.Close()
	db, err = relaydb.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	saved, err := db.HiddenLANEndpoints(context.Background())
	if err != nil || len(saved) != 1 {
		t.Fatal("pairing visibility lost on restart")
	}
	h.SetLANVisibility(db, nil)
	response = call(`{"hiddenBaseUrls":[]}`, true)
	var restored ServerURLsResponse
	if err = json.Unmarshal(response.Body.Bytes(), &restored); err != nil {
		t.Fatal(err)
	}
	if restored.LAN[0].Hidden == nil || *restored.LAN[0].Hidden {
		t.Fatal("restore did not publish explicit visible flag")
	}
	if restored.ConnectionRevision == hidden.ConnectionRevision {
		t.Fatal("visibility restore did not change revision")
	}
}

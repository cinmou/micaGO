package httpapi

import (
	"context"
	"crypto/tls"
	"database/sql"
	"errors"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"micagoserver/internal/realtime"
	"micagoserver/internal/relaydb"
	"nhooyr.io/websocket"
)

func TestDeviceCredentialsPairRevokeAndSocket(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "relay.db")
	db, err := relaydb.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	hub := realtime.NewHub()
	defer hub.Close()
	auth := NewDeviceAuth(db, hub, "old-shared-token", "pin")
	code, _, err := db.CreatePairingCode(ctx)
	if err != nil {
		t.Fatal(err)
	}
	id, token, err := db.RedeemPairingCode(ctx, code)
	if err != nil {
		t.Fatal(err)
	}
	_, _, err = db.RedeemPairingCode(ctx, code)
	if err == nil {
		t.Fatal("invitation reused")
	}
	mux := http.NewServeMux()
	mux.Handle("/api/chats", auth.Wrap(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if deviceIdentity(r) != id {
			t.Error("identity not derived from credential")
		}
		w.WriteHeader(204)
	})))
	mux.Handle("/api/server/notifications", auth.Wrap(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) })))
	mux.Handle("/api/devices/another/heartbeat", auth.Wrap(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) })))
	mux.HandleFunc("/ws", auth.Socket)
	server := httptest.NewTLSServer(mux)
	defer server.Close()
	request := func(path, credential string) int {
		req, _ := http.NewRequest("GET", server.URL+path, nil)
		req.Header.Set("Authorization", "Bearer "+credential)
		res, err := server.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		return res.StatusCode
	}
	if request("/api/chats", token) != 204 {
		t.Fatal("device rejected")
	}
	if request("/api/chats", "old-shared-token") != 401 {
		t.Fatal("legacy/admin token accepted over TLS")
	}
	if request("/api/server/notifications", token) != 403 || request("/api/devices/another/heartbeat", token) != 403 {
		t.Fatal("device exceeded permission")
	}
	headers := http.Header{}
	headers.Set("Authorization", "Bearer "+token)
	socket, _, err := websocket.Dial(ctx, strings.Replace(server.URL, "https:", "wss:", 1)+"/ws", &websocket.DialOptions{HTTPClient: server.Client(), HTTPHeader: headers})
	if err != nil {
		t.Fatal(err)
	}
	defer socket.CloseNow()
	deadline := time.Now().Add(time.Second)
	for hub.ClientCount() != 1 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if hub.ClientCount() != 1 {
		t.Fatal("socket not registered")
	}
	if err = auth.Revoke(ctx, id); err != nil {
		t.Fatal(err)
	}
	if hub.ClientCount() != 0 || request("/api/chats", token) != 401 {
		t.Fatal("revoked device retained access")
	}
	readCtx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	if _, _, err = socket.Read(readCtx); err == nil {
		t.Fatal("revoked socket stayed open")
	}
	// Local address alone must not make TLS clients administrators.
	req := httptest.NewRequest("GET", "/api/chats", nil)
	req.RemoteAddr = "127.0.0.1:1234"
	req.TLS = &tls.ConnectionState{}
	req.Header.Set("Authorization", "Bearer old-shared-token")
	if _, status := auth.authorize(req); status == http.StatusOK {
		t.Fatal("TLS administrator bypass")
	}
}

func TestPairingAtomicExpiryAndPersistence(t *testing.T) {
	path := filepath.Join(t.TempDir(), "relay.db")
	db, err := relaydb.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	code, _, err := db.CreatePairingCode(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	var mu sync.Mutex
	count := 0
	var credential, id string
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			device, token, err := db.RedeemPairingCode(ctx, code)
			if err == nil {
				mu.Lock()
				count++
				id = device
				credential = token
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if count != 1 {
		t.Fatalf("redeemed %d times", count)
	}
	db.Close()
	db, err = relaydb.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	got, err := db.DeviceForToken(ctx, credential)
	if err != nil || got != id {
		t.Fatal("credential lost on restart")
	}
	replacement, _, err := db.CreatePairingCode(ctx)
	if err != nil {
		t.Fatal(err)
	}
	newer, _, err := db.CreatePairingCode(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err = db.RedeemPairingCode(ctx, replacement); err == nil {
		t.Fatal("replaced invitation accepted")
	}
	// Credential and invitation are hashes, not raw bearer secrets, in SQLite.
	if strings.Contains(newer, credential) {
		t.Fatal("invalid random credentials")
	}
	if err = db.RevokeDevice(ctx, id); err != nil {
		t.Fatal(err)
	}
	db.Close()
	db, err = relaydb.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err = db.DeviceForToken(ctx, credential); err == nil {
		t.Fatal("revoke lost on restart")
	}
}

func TestPairingStatusIsLocalAdminOnly(t *testing.T) {
	db, err := relaydb.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	hub := realtime.NewHub()
	defer hub.Close()
	auth := NewDeviceAuth(db, hub, "test-admin", "pin")
	code, _, err := db.CreatePairingCode(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		remote, token, forwarded string
		want                     int
	}{
		{"127.0.0.1:1234", "test-admin", "", 200},
		{"192.168.1.2:1234", "test-admin", "", 401},
		{"127.0.0.1:1234", "wrong", "", 401},
		{"127.0.0.1:1234", "test-admin", "192.168.1.2", 401},
	} {
		req := httptest.NewRequest("POST", "http://localhost/api/pairing/status", strings.NewReader(`{"pairingCode":"`+code+`"}`))
		req.RemoteAddr = tc.remote
		req.Header.Set("Authorization", "Bearer "+tc.token)
		if tc.forwarded != "" {
			req.Header.Set("X-Forwarded-For", tc.forwarded)
		}
		rec := httptest.NewRecorder()
		auth.CodeStatus(rec, req)
		if rec.Code != tc.want {
			t.Fatalf("got %d want %d", rec.Code, tc.want)
		}
		if strings.Contains(rec.Body.String(), code) {
			t.Fatal("status leaks invitation")
		}
		if tc.want == 200 && !strings.Contains(rec.Body.String(), `"active"`) {
			t.Fatal("missing active status")
		}
	}
}

// Lookup failure must not tell a client to permanently delete its credential.
type failingCredentialLookup struct {
	credentialStore
	err error
}

func (s failingCredentialLookup) DeviceForToken(context.Context, string) (string, error) {
	return "", s.err
}
func TestAuthorizationFailuresKeepTheirMeaning(t *testing.T) {
	ctx := context.Background()
	db, err := relaydb.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	code, _, err := db.CreatePairingCode(ctx)
	if err != nil {
		t.Fatal(err)
	}
	id, token, err := db.RedeemPairingCode(ctx, code)
	if err != nil {
		t.Fatal(err)
	}
	hub := realtime.NewHub()
	defer hub.Close()
	for _, tc := range []struct {
		name, path string
		store      credentialStore
		status     int
	}{
		{"lookup locked", "/api/chats", failingCredentialLookup{db, errors.New("database is locked")}, http.StatusServiceUnavailable},
		{"lookup canceled", "/api/chats", failingCredentialLookup{db, context.Canceled}, http.StatusServiceUnavailable},
		{"unknown credential", "/api/chats", failingCredentialLookup{db, sql.ErrNoRows}, http.StatusUnauthorized},
		{"forbidden endpoint", "/api/server/notifications", db, http.StatusForbidden},
	} {
		t.Run(tc.name, func(t *testing.T) {
			auth := NewDeviceAuth(tc.store, hub, "test-admin", "pin")
			r := httptest.NewRequest(http.MethodGet, tc.path, nil)
			r.Header.Set("Authorization", "Bearer "+token)
			w := httptest.NewRecorder()
			auth.Wrap(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { t.Fatal("unauthorized handler invoked") })).ServeHTTP(w, r)
			if w.Code != tc.status {
				t.Fatalf("got %d, want %d", w.Code, tc.status)
			}
			if got, err := db.DeviceForToken(ctx, token); err != nil || got != id {
				t.Fatal("valid credential changed")
			}
		})
	}
}

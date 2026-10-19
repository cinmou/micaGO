package httpapi

import (
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"micagoserver/internal/config"
	"micagoserver/internal/relaydb"
	"path/filepath"
)

func TestHealthIsUnauthenticated(t *testing.T) {
	router := NewRouter(
		NewHandlers(&stubQueries{}, log.New(io.Discard, "", 0), nil, nil, "", &stubDeviceStore{}, stubNotifier{}, config.Config{HTTPAddr: "127.0.0.1:3000"}, StatusDeps{}),
		nil,
		newTestAuth(t, "secret"),
	)

	req := newLocalRequest(http.MethodGet, "/api/health", nil)
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
}

func TestAuthMissingWrongAndCorrect(t *testing.T) {
	router := NewRouter(
		NewHandlers(&stubQueries{}, log.New(io.Discard, "", 0), nil, nil, "", &stubDeviceStore{}, stubNotifier{}, config.Config{HTTPAddr: "127.0.0.1:3000"}, StatusDeps{}),
		nil,
		newTestAuth(t, "secret"),
	)

	for _, tc := range []struct {
		name   string
		header string
		want   int
	}{
		{name: "missing", header: "", want: http.StatusUnauthorized},
		{name: "wrong", header: "Bearer nope", want: http.StatusUnauthorized},
		{name: "correct", header: "Bearer secret", want: http.StatusOK},
	} {
		t.Run(tc.name, func(t *testing.T) {
			req := newLocalRequest(http.MethodGet, "/api/chats", nil)
			if tc.header != "" {
				req.Header.Set("Authorization", tc.header)
			}
			rec := httptest.NewRecorder()
			router.ServeHTTP(rec, req)
			if rec.Code != tc.want {
				t.Fatalf("expected %d, got %d", tc.want, rec.Code)
			}
		})
	}
}

func TestServerInfoDoesNotExposeToken(t *testing.T) {
	router := NewRouter(
		NewHandlers(&stubQueries{}, log.New(io.Discard, "", 0), nil, nil, "", &stubDeviceStore{}, stubNotifier{}, config.Config{
			HTTPAddr:  "127.0.0.1:3000",
			PublicURL: "https://example.com",
		}, StatusDeps{}),
		nil,
		newTestAuth(t, "secret"),
	)

	req := newLocalRequest(http.MethodGet, "/api/server/info", nil)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	if strings.Contains(rec.Body.String(), "secret") {
		t.Fatalf("response leaked token: %s", rec.Body.String())
	}
}

func TestEmptyConfiguredTokenNeverAuthenticates(t *testing.T) {
	auth := newTestAuth(t, "")
	for _, target := range []string{"/ws", "/ws?token="} {
		r := newLocalRequest(http.MethodGet, target, nil)
		r.Header.Set("Authorization", "Bearer ")
		if _, ok := auth.authorize(r); ok {
			t.Fatal("empty configured token authenticated")
		}
	}
}

func newTestAuth(t *testing.T, token string) *DeviceAuth {
	t.Helper()
	db, err := relaydb.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return NewDeviceAuth(db, nil, token, "test-pin")
}

func newLocalRequest(method, target string, body io.Reader) *http.Request {
	r := httptest.NewRequest(method, target, body)
	r.RemoteAddr = "127.0.0.1:12345"
	return r
}

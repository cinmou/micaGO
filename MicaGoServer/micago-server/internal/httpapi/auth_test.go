package httpapi

import (
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"micagoserver/internal/config"
)

func TestHealthIsUnauthenticated(t *testing.T) {
	router := NewRouter(
		NewHandlers(&stubQueries{}, log.New(io.Discard, "", 0), nil, nil, "", &stubDeviceStore{}, stubNotifier{}, config.Config{HTTPAddr: "127.0.0.1:3000"}, StatusDeps{}),
		nil,
		AuthConfig{Enabled: true, Token: "secret"},
	)

	req := httptest.NewRequest(http.MethodGet, "/api/health", nil)
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
		AuthConfig{Enabled: true, Token: "secret"},
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
			req := httptest.NewRequest(http.MethodGet, "/api/chats", nil)
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

func TestAuthLogsRejectedDeviceRegistration(t *testing.T) {
	var logs strings.Builder
	router := NewRouter(
		NewHandlers(&stubQueries{}, log.New(io.Discard, "", 0), nil, nil, "", &stubDeviceStore{}, stubNotifier{}, config.Config{HTTPAddr: "127.0.0.1:3000"}, StatusDeps{}),
		nil,
		AuthConfig{
			Enabled: true,
			Token:   "secret",
			Logger:  log.New(&logs, "", 0),
		},
	)

	req := httptest.NewRequest(http.MethodPost, "/api/devices/register", strings.NewReader(`{}`))
	req.Header.Set("Authorization", "Bearer wrong")
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
	if got := logs.String(); !strings.Contains(got, "auth rejected POST /api/devices/register") {
		t.Fatalf("missing auth rejection log: %q", got)
	}
}

func TestServerInfoDoesNotExposeToken(t *testing.T) {
	router := NewRouter(
		NewHandlers(&stubQueries{}, log.New(io.Discard, "", 0), nil, nil, "", &stubDeviceStore{}, stubNotifier{}, config.Config{
			HTTPAddr:  "127.0.0.1:3000",
			PublicURL: "https://example.com",
		}, StatusDeps{}),
		nil,
		AuthConfig{Enabled: true, Token: "secret"},
	)

	req := httptest.NewRequest(http.MethodGet, "/api/server/info", nil)
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
	auth := AuthConfig{Enabled: true}
	for _, target := range []string{"/ws", "/ws?token="} {
		r := httptest.NewRequest(http.MethodGet, target, nil)
		r.Header.Set("Authorization", "Bearer ")
		if auth.ValidateRequest(r) || auth.ValidateWebSocketRequest(r) {
			t.Fatal("empty configured token authenticated")
		}
	}
}

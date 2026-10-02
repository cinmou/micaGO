package httpapi

import (
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestAuthenticatedRequestLimits(t *testing.T) {
	auth := AuthConfig{Enabled: true, Token: "test-token"}
	for _, tc := range []struct {
		path, pattern string
		size          int64
		want          int
	}{
		{"/api/sync/settings", "PUT /api/sync/settings", maxJSONRequestBytes + 1, 413},
		{"/api/chats/a/send-attachment", "POST /api/chats/{guid}/send-attachment", maxOutgoingAttachmentBytes + multipartOverheadBytes + 1, 413},
		{"/api/chats/a/send-attachment", "POST /api/chats/{guid}/send-attachment", maxOutgoingAttachmentBytes, 200},
		{"/api/chats/a/send-attachments", "POST /api/chats/{guid}/send-attachments", maxBatchUploadBytes + multipartOverheadBytes + 1, 413},
	} {
		t.Run(tc.pattern, func(t *testing.T) {
			called := false
			handler := auth.Wrap(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { called = true; w.WriteHeader(200) }))
			r := httptest.NewRequest(http.MethodPost, tc.path, strings.NewReader("x"))
			r.Pattern = tc.pattern
			r.ContentLength = tc.size
			r.Header.Set("Authorization", "Bearer test-token")
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, r)
			if w.Code != tc.want || called != (tc.want == 200) {
				t.Fatalf("status=%d called=%t", w.Code, called)
			}
		})
	}
}

func TestChunkedBodyCannotBypassLimit(t *testing.T) {
	auth := AuthConfig{Enabled: true, Token: "test-token"}
	var count int64
	handler := auth.Wrap(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var err error
		count, err = io.Copy(io.Discard, r.Body)
		var tooLarge *http.MaxBytesError
		if !errors.As(err, &tooLarge) {
			t.Fatalf("expected bounded body, got %v", err)
		}
		w.WriteHeader(413)
	}))
	r := httptest.NewRequest(http.MethodPut, "/api/sync/settings", strings.NewReader(strings.Repeat("x", int(maxJSONRequestBytes+1))))
	r.ContentLength = -1
	r.Header.Set("Authorization", "Bearer test-token")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != 413 || count != maxJSONRequestBytes {
		t.Fatalf("status=%d read=%d", w.Code, count)
	}
}

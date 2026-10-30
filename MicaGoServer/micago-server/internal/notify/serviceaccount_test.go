package notify

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"cloud.google.com/go/auth"
)

func googleSource(t *testing.T, client *http.Client) *TokenSource {
	t.Helper()
	sa, err := ParseServiceAccount(testServiceAccountJSON(t))
	if err != nil {
		t.Fatal(err)
	}
	source, err := NewTokenSource(sa, client, scopeFCM, scopeFirestore)
	if err != nil {
		t.Fatal(err)
	}
	return source
}

func tokenResponse(status int, body string) *http.Response {
	return &http.Response{StatusCode: status, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body))}
}

func TestGoogleTokenExchangeAndConcurrentCache(t *testing.T) {
	var requests atomic.Int32
	source := googleSource(t, &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		requests.Add(1)
		if r.Method != http.MethodPost || r.URL.String() != "https://oauth2.googleapis.com/token" {
			return nil, errors.New("unexpected OAuth endpoint")
		}
		if err := r.ParseForm(); err != nil {
			return nil, err
		}
		if r.Form.Get("grant_type") != "urn:ietf:params:oauth:grant-type:jwt-bearer" {
			return nil, errors.New("incorrect OAuth grant")
		}
		parts := strings.Split(r.Form.Get("assertion"), ".")
		if len(parts) != 3 {
			return nil, errors.New("invalid signed assertion")
		}
		var claims struct {
			Iss   string
			Scope string
			Aud   string
		}
		raw, err := base64.RawURLEncoding.DecodeString(parts[1])
		if err != nil {
			return nil, err
		}
		if err = json.Unmarshal(raw, &claims); err != nil {
			return nil, err
		}
		if claims.Iss != "svc@demo-project.iam.gserviceaccount.com" || claims.Scope != scopeFCM+" "+scopeFirestore || claims.Aud != r.URL.String() {
			return nil, errors.New("incorrect service account or scopes")
		}
		return tokenResponse(200, `{"access_token":"cached-token","token_type":"Bearer","expires_in":3600}`), nil
	})})
	var wg sync.WaitGroup
	failures := make(chan error, 16)
	for i := 0; i < 16; i++ {
		wg.Go(func() {
			token, err := source.Token(context.Background())
			if err != nil {
				failures <- err
			} else if token != "cached-token" {
				failures <- errors.New("wrong cached token")
			}
		})
	}
	wg.Wait()
	close(failures)
	for err := range failures {
		t.Error(err)
	}
	if requests.Load() != 1 {
		t.Fatalf("expected one exchange for concurrent callers, got %d", requests.Load())
	}
}

func TestGoogleTokenRefreshesOneMinuteEarly(t *testing.T) {
	var requests atomic.Int32
	source := googleSource(t, &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		n := requests.Add(1)
		expiry := 3600
		if n == 1 {
			expiry = 30
		}
		return tokenResponse(200, fmt.Sprintf(`{"access_token":"token-%d","expires_in":%d}`, n, expiry)), nil
	})})
	for _, expected := range []string{"token-1", "token-2", "token-2"} {
		token, err := source.Token(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		if token != expected {
			t.Fatalf("unexpected token generation: got %s, want %s", token, expected)
		}
	}
	if requests.Load() != 2 {
		t.Fatal("early refresh or token reuse failed")
	}
}

func TestGoogleTokenCancellationAndTimeout(t *testing.T) {
	for _, timeout := range []bool{false, true} {
		t.Run(fmt.Sprint("timeout=", timeout), func(t *testing.T) {
			started := make(chan struct{})
			client := &http.Client{Timeout: time.Second, Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				close(started)
				<-r.Context().Done()
				return nil, r.Context().Err()
			})}
			if timeout {
				client.Timeout = 30 * time.Millisecond
			}
			source := googleSource(t, client)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			result := make(chan error, 1)
			go func() { _, err := source.Token(ctx); result <- err }()
			select {
			case <-started:
			case <-time.After(2 * time.Second):
				t.Fatal("token exchange did not start")
			}
			want := context.DeadlineExceeded
			if !timeout {
				cancel()
				want = context.Canceled
			}
			select {
			case err := <-result:
				if !errors.Is(err, want) {
					t.Fatalf("lost cancellation/timeout cause: %v", err)
				}
				if strings.Contains(err.Error(), "rejected") {
					t.Fatal("transport failure was reported as credential rejection")
				}
			case <-time.After(2 * time.Second):
				t.Fatal("token exchange ignored cancellation or timeout")
			}
		})
	}
}

func TestGoogleTokenFailureIsSafeAndRetryable(t *testing.T) {
	var requests atomic.Int32
	source := googleSource(t, &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		if requests.Add(1) == 1 {
			return tokenResponse(503, `{"error":"temporary","error_description":"PRIVATE_RESPONSE_MARKER"}`), nil
		}
		return tokenResponse(200, `{"access_token":"recovered","expires_in":3600}`), nil
	})})
	_, err := source.Token(context.Background())
	var responseError *auth.Error
	if !errors.As(err, &responseError) || responseError.Response.StatusCode != 503 {
		t.Fatalf("lost HTTP failure: %v", err)
	}
	if strings.Contains(err.Error(), "PRIVATE_RESPONSE_MARKER") || !strings.Contains(err.Error(), "HTTP 503") {
		t.Fatal("unsafe or misleading OAuth error")
	}
	token, err := source.Token(context.Background())
	if err != nil || token != "recovered" {
		t.Fatal("temporary OAuth failure prevented later recovery")
	}
}

func TestGoogleTokenRejectsIncompleteResponses(t *testing.T) {
	for _, body := range []string{`{}`, `{"access_token":"no-expiry"}`, `{"expires_in":3600}`, `invalid JSON`} {
		t.Run(body, func(t *testing.T) {
			var requests atomic.Int32
			source := googleSource(t, &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) { requests.Add(1); return tokenResponse(200, body), nil })})
			for i := 0; i < 2; i++ {
				if _, err := source.Token(context.Background()); err == nil {
					t.Fatal("incomplete token response accepted")
				}
			}
			if requests.Load() != 2 {
				t.Fatal("malformed response was cached")
			}
		})
	}
}

func TestGoogleSDKDoesNotLogAssertionsOrTokens(t *testing.T) {
	t.Setenv("GOOGLE_SDK_GO_LOGGING_LEVEL", "DEBUG")
	previous := os.Stderr
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	os.Stderr = writer
	defer func() { os.Stderr = previous; writer.Close() }()
	source := googleSource(t, &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		return tokenResponse(200, `{"access_token":"PRIVATE_TOKEN_MARKER","expires_in":3600}`), nil
	})})
	if _, err := source.Token(context.Background()); err != nil {
		t.Fatal(err)
	}
	writer.Close()
	output, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	if len(output) != 0 {
		t.Fatal("Google SDK request or response logging was enabled")
	}
}

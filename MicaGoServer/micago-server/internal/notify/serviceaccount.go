package notify

import (
	"context"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"cloud.google.com/go/auth"
)

// FCM + Firestore OAuth2 scopes (one token serves both).
const (
	scopeFCM       = "https://www.googleapis.com/auth/firebase.messaging"
	scopeFirestore = "https://www.googleapis.com/auth/datastore"
)

// ServiceAccount is the minimal subset of a Google service-account JSON the
// provider needs. The file stays on the Mac; its contents are never returned by
// any API or logged.
type ServiceAccount struct {
	Type         string `json:"type"`
	ProjectID    string `json:"project_id"`
	PrivateKeyID string `json:"private_key_id"`
	PrivateKey   string `json:"private_key"`
	ClientEmail  string `json:"client_email"`
	TokenURI     string `json:"token_uri"`
}

// LoadServiceAccount reads and validates a service-account JSON file.
func LoadServiceAccount(path string) (*ServiceAccount, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("service account file could not be read")
	}
	return ParseServiceAccount(data)
}

// ParseServiceAccount validates the required fields of a service-account JSON.
func ParseServiceAccount(data []byte) (*ServiceAccount, error) {
	var sa ServiceAccount
	if err := json.Unmarshal(data, &sa); err != nil {
		return nil, fmt.Errorf("parse service account JSON: %w", err)
	}
	if sa.Type != "service_account" {
		return nil, fmt.Errorf("expected a Google service_account credential")
	}
	if strings.TrimSpace(sa.ClientEmail) == "" || strings.TrimSpace(sa.PrivateKey) == "" {
		return nil, fmt.Errorf("service account missing client_email or private_key")
	}
	if sa.TokenURI == "" {
		sa.TokenURI = "https://oauth2.googleapis.com/token"
	}
	if err := sa.validatePrivateKey(); err != nil {
		return nil, err
	}
	return &sa, nil
}

func (sa *ServiceAccount) validatePrivateKey() error {
	block, _ := pem.Decode([]byte(sa.PrivateKey))
	if block == nil {
		return errors.New("service account private_key is not valid PEM")
	}
	if key, err := x509.ParsePKCS8PrivateKey(block.Bytes); err == nil {
		if _, ok := key.(*rsa.PrivateKey); ok {
			return nil
		}
		return errors.New("service account key is not RSA")
	}
	if _, err := x509.ParsePKCS1PrivateKey(block.Bytes); err == nil {
		return nil
	}
	return errors.New("could not parse service account private key")
}

// TokenSource 将 Google 的签名、换令牌和缓存接入通知接口。
type TokenSource struct {
	provider auth.TokenProvider
}

func NewTokenSource(sa *ServiceAccount, client *http.Client, scopes ...string) (*TokenSource, error) {
	if client == nil {
		client = &http.Client{Timeout: 15 * time.Second}
	}
	provider, err := auth.New2LOTokenProvider(&auth.Options2LO{
		Email:        sa.ClientEmail,
		PrivateKey:   []byte(sa.PrivateKey),
		PrivateKeyID: sa.PrivateKeyID,
		TokenURL:     sa.TokenURI,
		Scopes:       scopes,
		Client:       client,
		// SDK debug logging can include JWT assertions and token response bodies.
		// Keep it disabled even if GOOGLE_SDK_GO_LOGGING_LEVEL is set globally.
		Logger: slog.New(slog.DiscardHandler),
	})
	if err != nil {
		return nil, fmt.Errorf("initialize Google authorization: %w", err)
	}
	fetch := googleTokenFetch(func(ctx context.Context) (*auth.Token, error) {
		token, err := provider.Token(ctx)
		if err != nil {
			return nil, err
		}
		// Google access tokens expire. Do not let a malformed response become
		// an indefinitely cached token (the library permits zero expiry).
		if token.Value == "" || token.Expiry.IsZero() {
			return nil, errors.New("Google OAuth response missing access_token or expires_in")
		}
		return token, nil
	})
	return &TokenSource{provider: auth.NewCachedTokenProvider(fetch, &auth.CachedTokenProviderOptions{
		ExpireEarly: time.Minute,
		// Refresh inside the caller's context, never in an unowned background task.
		DisableAsyncRefresh: true,
	})}, nil
}

func (ts *TokenSource) Token(ctx context.Context) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	token, err := ts.provider.Token(ctx)
	if err != nil {
		return "", googleTokenError{cause: err}
	}
	return token.Value, nil
}

type googleTokenFetch func(context.Context) (*auth.Token, error)

func (f googleTokenFetch) Token(ctx context.Context) (*auth.Token, error) { return f(ctx) }

// The SDK error can include Google's raw response body. Expose only status or
// transport failure here; preserve the cause for errors.Is/As without logging it.
type googleTokenError struct{ cause error }

func (e googleTokenError) Unwrap() error { return e.cause }

func (e googleTokenError) Error() string {
	if errors.Is(e.cause, context.Canceled) {
		return "Google OAuth token request canceled"
	}
	if errors.Is(e.cause, context.DeadlineExceeded) {
		return "Google OAuth token request deadline exceeded"
	}
	var responseError *auth.Error
	if errors.As(e.cause, &responseError) && responseError.Response != nil {
		return fmt.Sprintf("Google OAuth token request failed: HTTP %d", responseError.Response.StatusCode)
	}
	var networkError net.Error
	if errors.As(e.cause, &networkError) && networkError.Timeout() {
		return "Google OAuth token request timed out"
	}
	return "Google OAuth token request failed"
}

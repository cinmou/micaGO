package notify

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
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
	if strings.TrimSpace(sa.ClientEmail) == "" || strings.TrimSpace(sa.PrivateKey) == "" {
		return nil, fmt.Errorf("service account missing client_email or private_key")
	}
	if sa.TokenURI == "" {
		sa.TokenURI = "https://oauth2.googleapis.com/token"
	}
	if _, err := sa.parsedKey(); err != nil {
		return nil, err
	}
	return &sa, nil
}

func (sa *ServiceAccount) parsedKey() (*rsa.PrivateKey, error) {
	block, _ := pem.Decode([]byte(sa.PrivateKey))
	if block == nil {
		return nil, fmt.Errorf("service account private_key is not valid PEM")
	}
	if key, err := x509.ParsePKCS8PrivateKey(block.Bytes); err == nil {
		if rsaKey, ok := key.(*rsa.PrivateKey); ok {
			return rsaKey, nil
		}
		return nil, fmt.Errorf("service account key is not RSA")
	}
	if rsaKey, err := x509.ParsePKCS1PrivateKey(block.Bytes); err == nil {
		return rsaKey, nil
	}
	return nil, fmt.Errorf("could not parse service account private key")
}

// TokenSource mints and caches OAuth2 access tokens from a service account via
// the JWT-bearer grant. Safe for concurrent use.
type TokenSource struct {
	sa     *ServiceAccount
	scopes []string
	client *http.Client

	mu      sync.Mutex
	token   string
	expires time.Time
}

func NewTokenSource(sa *ServiceAccount, client *http.Client, scopes ...string) *TokenSource {
	if client == nil {
		client = &http.Client{Timeout: 15 * time.Second}
	}
	return &TokenSource{sa: sa, scopes: scopes, client: client}
}

// Token returns a cached access token, refreshing when fewer than 60s remain.
func (ts *TokenSource) Token(ctx context.Context) (string, error) {
	ts.mu.Lock()
	defer ts.mu.Unlock()
	if ts.token != "" && time.Until(ts.expires) > 60*time.Second {
		return ts.token, nil
	}

	assertion, err := ts.signedAssertion(time.Now())
	if err != nil {
		return "", err
	}
	form := url.Values{}
	form.Set("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer")
	form.Set("assertion", assertion)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, ts.sa.TokenURI, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := ts.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("oauth token request: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("oauth token request failed: HTTP %d", resp.StatusCode)
	}
	var out struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", fmt.Errorf("decode oauth token: %w", err)
	}
	if out.AccessToken == "" {
		return "", fmt.Errorf("oauth token response had no access_token")
	}
	ts.token = out.AccessToken
	ts.expires = time.Now().Add(time.Duration(out.ExpiresIn) * time.Second)
	return ts.token, nil
}

// signedAssertion builds and RS256-signs the JWT used for the token exchange.
func (ts *TokenSource) signedAssertion(now time.Time) (string, error) {
	key, err := ts.sa.parsedKey()
	if err != nil {
		return "", err
	}
	header := map[string]string{"alg": "RS256", "typ": "JWT"}
	if ts.sa.PrivateKeyID != "" {
		header["kid"] = ts.sa.PrivateKeyID
	}
	claims := map[string]any{
		"iss":   ts.sa.ClientEmail,
		"scope": strings.Join(ts.scopes, " "),
		"aud":   ts.sa.TokenURI,
		"iat":   now.Unix(),
		"exp":   now.Add(time.Hour).Unix(),
	}
	headerJSON, _ := json.Marshal(header)
	claimsJSON, _ := json.Marshal(claims)
	signingInput := b64url(headerJSON) + "." + b64url(claimsJSON)

	digest := sha256.Sum256([]byte(signingInput))
	sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
	if err != nil {
		return "", fmt.Errorf("sign JWT: %w", err)
	}
	return signingInput + "." + b64url(sig), nil
}

func b64url(b []byte) string {
	return base64.RawURLEncoding.EncodeToString(b)
}

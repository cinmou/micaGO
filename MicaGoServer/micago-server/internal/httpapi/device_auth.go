package httpapi

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"micagoserver/internal/realtime"
)

type credentialStore interface {
	CreatePairingCode(context.Context) (string, int64, error)
	PairingCodeStatus(context.Context, string) (string, error)
	RedeemPairingCode(context.Context, string) (string, string, error)
	DeviceForToken(context.Context, string) (string, error)
	RevokeDevice(context.Context, string) error
}
type deviceAuthKey struct{}

// DeviceAuth serializes pairing, revocation and socket admission. Request
// identity comes from the credential lookup, never from client metadata.
type DeviceAuth struct {
	mu          sync.Mutex
	store       credentialStore
	hub         *realtime.Hub
	adminToken  string
	fingerprint string
	probeToken  string
	lookupSlots chan struct{}
	rateMu      sync.Mutex
	rateTokens  float64
	rateUpdated time.Time
}

func NewDeviceAuth(store credentialStore, hub *realtime.Hub, adminToken, fingerprint string) *DeviceAuth {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("secure random unavailable")
	}
	return &DeviceAuth{lookupSlots: make(chan struct{}, 16), rateTokens: 240, rateUpdated: time.Now(), store: store, hub: hub, adminToken: adminToken, fingerprint: fingerprint, probeToken: hex.EncodeToString(b[:])}
}
func localControl(r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	return err == nil && net.ParseIP(host).IsLoopback() && r.TLS == nil && r.Header.Get("Forwarded") == "" && r.Header.Get("X-Forwarded-For") == "" && r.Header.Get("X-Forwarded-Proto") == ""
}
func requestToken(r *http.Request) string {
	value := r.Header.Get("Authorization")
	if !strings.HasPrefix(value, "Bearer ") {
		return ""
	}
	return strings.TrimSpace(strings.TrimPrefix(value, "Bearer "))
}
func deviceIdentity(r *http.Request) string {
	id, _ := r.Context().Value(deviceAuthKey{}).(string)
	return id
}
func (a *DeviceAuth) authorize(r *http.Request) (*http.Request, int) {
	token := requestToken(r)
	if localControl(r) && constantTimeEqual(token, a.adminToken) {
		return r, http.StatusOK
	}
	if r.URL.Path == "/api/auth/check" && r.Method == http.MethodPost && constantTimeEqual(token, a.probeToken) {
		return r, http.StatusOK
	}
	// Old global pairing tokens never grant remote access.
	if len(token) != 64 {
		return r, http.StatusUnauthorized
	}
	if !a.allowCredentialLookup() {
		return r, http.StatusTooManyRequests
	}
	select {
	case a.lookupSlots <- struct{}{}:
		defer func() { <-a.lookupSlots }()
	default:
		return r, http.StatusServiceUnavailable
	}
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	id, err := a.store.DeviceForToken(ctx, token)
	if errors.Is(err, sql.ErrNoRows) {
		return r, http.StatusUnauthorized
	}
	if err != nil {
		return r, http.StatusServiceUnavailable
	}
	if id == "" {
		return r, http.StatusUnauthorized
	}
	if !clientRouteAllowed(r, id) {
		return r, http.StatusForbidden
	}
	return r.WithContext(context.WithValue(r.Context(), deviceAuthKey{}, id)), http.StatusOK
}

// Bound anonymous database work without retaining attacker-controlled IP keys.
// Loopback administrator requests bypass this budget in authorize.
func (a *DeviceAuth) allowCredentialLookup() bool {
	a.rateMu.Lock()
	defer a.rateMu.Unlock()
	now := time.Now()
	a.rateTokens = min(240, a.rateTokens+now.Sub(a.rateUpdated).Seconds()*120)
	a.rateUpdated = now
	if a.rateTokens < 1 {
		return false
	}
	a.rateTokens--
	return true
}

func clientRouteAllowed(r *http.Request, id string) bool {
	p := r.URL.Path
	switch r.Method {
	case http.MethodGet:
		switch p {
		case "/ws", "/api/server/info", "/api/server/status", "/api/server/urls",
			"/api/read-state", "/api/message-preferences", "/api/chat-preferences",
			"/api/messages/recent", "/api/messages/history", "/api/messages/delta",
			"/api/messages/actions/capabilities", "/api/chats", "/api/fcm/client", "/api/push/unifiedpush",
			"/api/sync/settings", "/api/sync/rules", "/api/test-contact":
			return true
		}
	case http.MethodPost:
		switch p {
		case "/api/auth/check", "/api/devices/register", "/api/sync/now", "/api/messages/actions/refresh":
			return true
		}
		if p == "/api/devices/"+id+"/heartbeat" {
			return true
		}
	case http.MethodPut:
		return p == "/api/chats/mute"
	case http.MethodPatch:
		switch p {
		case "/api/read-state", "/api/message-preferences", "/api/chat-preferences":
			return true
		}
		return p == "/api/devices/"+id
	case http.MethodDelete:
		if p == "/api/devices/"+id {
			return true
		}
	}
	parts := strings.Split(strings.Trim(p, "/"), "/")
	if len(parts) == 3 && parts[0] == "api" && parts[1] == "attachments" && r.Method == http.MethodGet {
		return true
	}
	if len(parts) < 4 || parts[0] != "api" {
		return false
	}
	if parts[1] == "attachments" && r.Method == http.MethodGet {
		return len(parts) == 4 && (parts[3] == "playable" || parts[3] == "preview")
	}
	if parts[1] != "chats" {
		return false
	}
	if len(parts) == 4 {
		return r.Method == http.MethodGet && parts[3] == "messages" ||
			r.Method == http.MethodPost && (parts[3] == "send" || parts[3] == "send-attachment" || parts[3] == "send-attachments")
	}
	return parts[3] == "messages" && (len(parts) == 5 && r.Method == http.MethodDelete ||
		len(parts) == 6 && r.Method == http.MethodPost && (parts[5] == "edit" || parts[5] == "retract"))
}
func (a *DeviceAuth) Wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authed, status := a.authorize(r)
		if status != http.StatusOK {
			writeAuthorizationFailure(w, status)
			return
		}
		if limitRequestBody(w, authed) {
			next.ServeHTTP(w, authed)
		}
	})
}
func (a *DeviceAuth) Socket(w http.ResponseWriter, r *http.Request) {
	if _, status := a.authorize(r); status != http.StatusOK {
		writeAuthorizationFailure(w, status)
		return
	}
	// Admission runs under the same lock as revoke; the hub registers the
	// connection before unlocking, so a concurrent revoke cannot miss it.
	a.mu.Lock()
	authed, status := a.authorize(r)
	if status != http.StatusOK {
		a.mu.Unlock()
		writeAuthorizationFailure(w, status)
		return
	}
	id := deviceIdentity(authed)
	a.hub.ServeAuthorized(w, authed, id, a.mu.Unlock)
}
func (a *DeviceAuth) CreateCode(w http.ResponseWriter, r *http.Request) {
	if !localControl(r) || !constantTimeEqual(requestToken(r), a.adminToken) {
		writeUnauthorized(w)
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	code, expires, err := a.store.CreatePairingCode(r.Context())
	if err != nil {
		writeInternalError(w)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"pairingCode": code, "expiresAt": expires, "tlsFingerprint": a.fingerprint})
}
func (a *DeviceAuth) Redeem(w http.ResponseWriter, r *http.Request) {
	if !a.allowCredentialLookup() {
		writeAuthorizationFailure(w, http.StatusTooManyRequests)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	r = r.WithContext(ctx)
	if !limitRequestBody(w, r) {
		return
	}
	_ = http.NewResponseController(w).SetReadDeadline(time.Now().Add(10 * time.Second))
	var req struct {
		PairingCode string `json:"pairingCode"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&req); err != nil || len(req.PairingCode) != 64 {
		writeBadRequest(w, "invalid pairing code")
		return
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		writeBadRequest(w, "expected one JSON object")
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	id, token, err := a.store.RedeemPairingCode(r.Context(), req.PairingCode)
	if err != nil {
		writeAPIError(w, http.StatusUnauthorized, "pairing_expired", "Pairing code expired or already used. Create a new code on the Mac.")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"deviceId": id, "token": token})
}
func (a *DeviceAuth) Revoke(ctx context.Context, id string) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if err := a.store.RevokeDevice(ctx, id); err != nil {
		return err
	}
	a.hub.DisconnectDevice(id)
	return nil
}

func (c *NetworkController) SecureProbe(auth *DeviceAuth) {
	c.secure = true
	c.authToken = auth.probeToken
	c.verifyTLS = true
}

// The control-only status endpoint keeps invitation secrets out of URLs/logs.
func (a *DeviceAuth) CodeStatus(w http.ResponseWriter, r *http.Request) {
	if !localControl(r) || !constantTimeEqual(requestToken(r), a.adminToken) {
		writeUnauthorized(w)
		return
	}
	_ = http.NewResponseController(w).SetReadDeadline(time.Now().Add(10 * time.Second))
	var req struct {
		PairingCode string `json:"pairingCode"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&req); err != nil || len(req.PairingCode) != 64 {
		writeBadRequest(w, "invalid pairing code")
		return
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		writeBadRequest(w, "expected one JSON object")
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	state, err := a.store.PairingCodeStatus(r.Context(), req.PairingCode)
	if err != nil {
		writeInternalError(w)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"state": state})
}

func constantTimeEqual(a, b string) bool {
	if b == "" || len(a) != len(b) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

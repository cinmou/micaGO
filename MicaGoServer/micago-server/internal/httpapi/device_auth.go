package httpapi

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
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
}

func NewDeviceAuth(store credentialStore, hub *realtime.Hub, adminToken, fingerprint string) *DeviceAuth {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("secure random unavailable")
	}
	return &DeviceAuth{store: store, hub: hub, adminToken: adminToken, fingerprint: fingerprint, probeToken: hex.EncodeToString(b[:])}
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
func (a *DeviceAuth) authorize(r *http.Request) (*http.Request, bool) {
	token := requestToken(r)
	if localControl(r) && constantTimeEqual(token, a.adminToken) {
		return r, true
	}
	if r.URL.Path == "/api/auth/check" && r.Method == http.MethodPost && constantTimeEqual(token, a.probeToken) {
		return r, true
	}
	// Old global pairing tokens never grant remote access.
	if len(token) != 64 {
		return r, false
	}
	id, err := a.store.DeviceForToken(r.Context(), token)
	if err != nil || id == "" {
		return r, false
	}
	if !clientRouteAllowed(r, id) {
		return r, false
	}
	return r.WithContext(context.WithValue(r.Context(), deviceAuthKey{}, id)), true
}
func clientRouteAllowed(r *http.Request, id string) bool {
	p := r.URL.Path
	if p == "/api/devices/register" {
		return true
	}
	if strings.HasPrefix(p, "/api/devices/") {
		return p == "/api/devices/"+id || p == "/api/devices/"+id+"/heartbeat"
	}
	if p == "/api/devices" || p == "/api/debug/recent-messages" {
		return false
	}
	if strings.HasPrefix(p, "/api/server/") {
		return r.Method == http.MethodGet && (p == "/api/server/info" || p == "/api/server/status" || p == "/api/server/urls") || p == "/api/server/notifications/preview" && r.Method == http.MethodPatch
	}

	return true
}
func (a *DeviceAuth) Wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		a.mu.Lock()
		authed, ok := a.authorize(r)
		a.mu.Unlock()
		if !ok {
			writeUnauthorized(w)
			return
		}
		if limitRequestBody(w, authed) {
			next.ServeHTTP(w, authed)
		}
	})
}
func (a *DeviceAuth) Socket(w http.ResponseWriter, r *http.Request) {
	// Admission runs under the same lock as revoke; the hub registers the
	// connection before unlocking, so a concurrent revoke cannot miss it.
	a.mu.Lock()
	authed, ok := a.authorize(r)
	if !ok {
		a.mu.Unlock()
		writeUnauthorized(w)
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

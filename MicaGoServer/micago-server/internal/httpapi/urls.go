package httpapi

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"micagoserver/internal/config"
	"micagoserver/internal/realtime"
)

// Connection-endpoint aggregation (v0.11). The server always exposes loopback
// (local) and, when bound appropriately, LAN endpoints. The public endpoint is
// an OPTIONAL EXTRA, configured by the user — never a replacement for, or a
// switchable mode against, local/LAN. See
// docs/spec-v0.11.0-connection-endpoints.md.

// Reachability is a tri-state that marshals as JSON `true`, `false`, or the
// string `"unknown"` (matching the documented wire shape).
type Reachability struct {
	known bool
	value bool
}

func reachableYes() Reachability     { return Reachability{known: true, value: true} }
func reachableNo() Reachability      { return Reachability{known: true, value: false} }
func reachableUnknown() Reachability { return Reachability{} }

func (r Reachability) MarshalJSON() ([]byte, error) {
	if !r.known {
		return []byte(`"unknown"`), nil
	}
	if r.value {
		return []byte("true"), nil
	}
	return []byte("false"), nil
}

func (r *Reachability) UnmarshalJSON(b []byte) error {
	switch strings.TrimSpace(string(b)) {
	case `"unknown"`:
		r.known, r.value = false, false
	case "true":
		r.known, r.value = true, true
	case "false":
		r.known, r.value = true, false
	default:
		return fmt.Errorf("invalid reachability %q", string(b))
	}
	return nil
}

// EndpointInfo is one reachable connection endpoint.
type EndpointInfo struct {
	Hidden    *bool        `json:"hidden,omitempty"`
	Kind      string       `json:"kind"` // loopback | lan
	Label     string       `json:"label"`
	BaseURL   string       `json:"baseUrl"`
	WSURL     string       `json:"wsUrl"`
	Reachable Reachability `json:"reachable"`
}

// PublicEndpoint is the optional, user-configured public endpoint.
type PublicEndpoint struct {
	Enabled       bool         `json:"enabled"`
	Kind          string       `json:"kind,omitempty"`
	BaseURL       string       `json:"baseUrl"`
	WSURL         string       `json:"wsUrl"`
	Reachable     Reachability `json:"reachable"`
	ProviderHint  string       `json:"providerHint,omitempty"`
	VerifyTLS     bool         `json:"verifyTls"`
	LastCheckedAt *int64       `json:"lastCheckedAt"`
}

// ServerURLsResponse is the GET /api/server/urls payload. C25: loopback/local
// is no longer part of the connection flow — Android can't use 127.0.0.1, so the
// only client-usable endpoints are LAN and the optional Public.
type ServerURLsResponse struct {
	LAN                      []EndpointInfo `json:"lan"`
	Public                   PublicEndpoint `json:"public"`
	PreferredPairingEndpoint string         `json:"preferredPairingEndpoint"`
	// ConnectionRevision (C23) is a short, stateless hash of the connection-
	// relevant settings (bind address + LAN/Public endpoints). It changes
	// whenever those change, so a paired client can detect that the server's
	// connection candidates moved and refresh them without rescanning a QR.
	ConnectionRevision string `json:"connectionRevision"`
	TLSFingerprint     string `json:"tlsFingerprint,omitempty"`
}

// PublicURLCheckResult is the POST /api/server/public-url/check payload. It
// never includes the bearer token.
type PublicURLCheckResult struct {
	OK        bool   `json:"ok"`
	Reachable bool   `json:"reachable"`
	AuthOK    bool   `json:"authOk"`
	Status    int    `json:"status"`
	BaseURL   string `json:"baseUrl"`
	Message   string `json:"message"`
}

// NetworkController owns the mutable public-endpoint settings, persists changes
// to the config file, and performs reachability checks. Local/LAN endpoints are
// derived statically from the bind address and are NOT part of this controller.
type NetworkController struct {
	secure        bool
	mu            sync.RWMutex
	configPath    string
	publicBaseURL string
	verifyTLS     bool
	preferred     string
	authToken     string // used only for the outbound reachability probe
	lastReachable Reachability
	lastCheckedAt int64
	// onChange is an optional hook fired (off the lock) after the public URL
	// changes — used by v0.12 to sync the URL to Firestore when enabled.
	onChange func(ctx context.Context, publicURL string)
}

// SetOnChange registers a callback invoked after the public URL is updated.
func (c *NetworkController) SetOnChange(fn func(ctx context.Context, publicURL string)) {
	c.mu.Lock()
	c.onChange = fn
	c.mu.Unlock()
}

func NewNetworkController(cfg config.Config) *NetworkController {
	return &NetworkController{
		configPath:    cfg.ConfigPath,
		publicBaseURL: strings.TrimSpace(cfg.PublicBaseURL),
		verifyTLS:     cfg.VerifyTLS,
		preferred:     cfg.PreferredPairingEndpoint,
		authToken:     cfg.AuthToken,
	}
}

type networkSnapshot struct {
	publicBaseURL string
	verifyTLS     bool
	preferred     string
	lastReachable Reachability
	lastCheckedAt int64
}

func (c *NetworkController) snapshot() networkSnapshot {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return networkSnapshot{
		publicBaseURL: c.publicBaseURL,
		verifyTLS:     c.verifyTLS,
		preferred:     c.preferred,
		lastReachable: c.lastReachable,
		lastCheckedAt: c.lastCheckedAt,
	}
}

// SetPublicURL validates, persists, and applies a new public endpoint. An empty
// url clears the public endpoint. Local/LAN endpoints are unaffected.
func (c *NetworkController) SetPublicURL(publicBaseURL string, verifyTLS bool, preferred string) error {
	trimmed := strings.TrimSpace(publicBaseURL)
	if preferred == "" {
		preferred = "auto"
	}
	if c.secure && trimmed != "" && (!strings.HasPrefix(trimmed, "https://") || !verifyTLS) {
		return fmt.Errorf("public endpoint requires HTTPS with certificate verification")
	}
	if err := config.UpdatePublicBaseURL(c.configPath, trimmed, verifyTLS, preferred); err != nil {
		return err
	}
	c.mu.Lock()
	c.publicBaseURL = trimmed
	c.verifyTLS = verifyTLS
	c.preferred = preferred
	c.lastReachable = reachableUnknown() // URL changed; previous result is stale
	c.lastCheckedAt = 0
	onChange := c.onChange
	c.mu.Unlock()

	if onChange != nil {
		onChange(context.Background(), trimmed)
	}
	return nil
}

// Check probes the configured public URL and confirms bearer auth works against
// THIS server. It updates the cached reachability used by GET /api/server/urls.
func (c *NetworkController) Check(ctx context.Context) PublicURLCheckResult {
	snap := c.snapshot()
	base := snap.publicBaseURL
	if base == "" {
		return PublicURLCheckResult{OK: false, Reachable: false, Message: "no public URL configured"}
	}

	if c.secure && !strings.HasPrefix(base, "https://") {
		return PublicURLCheckResult{OK: false, Reachable: false, BaseURL: base, Message: "public endpoint requires HTTPS"}
	}
	transport := &http.Transport{}
	if !snap.verifyTLS {
		transport.TLSClientConfig = &tls.Config{InsecureSkipVerify: true} // user opted out of TLS verification
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Timeout: 6 * time.Second, Transport: transport,
		// The user configured one origin. Never forward its bearer probe to a
		// redirected destination (including a TLS downgrade on the same host).
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}

	target := strings.TrimRight(base, "/") + "/api/auth/check"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, target, nil)
	result := PublicURLCheckResult{BaseURL: base}
	if err != nil {
		result.Message = "could not build request: " + err.Error()
		return result
	}
	if c.authToken != "" {
		req.Header.Set("Authorization", "Bearer "+c.authToken)
	}

	resp, err := client.Do(req)
	if err != nil {
		result.Reachable = false
		result.Message = "could not reach public URL: " + err.Error()
		c.record(reachableNo())
		return result
	}
	defer resp.Body.Close()

	result.Reachable = true
	result.Status = resp.StatusCode
	if resp.StatusCode == http.StatusOK {
		var check struct {
			OK bool `json:"ok"`
		}
		decoder := json.NewDecoder(io.LimitReader(resp.Body, 64<<10))
		result.AuthOK = decoder.Decode(&check) == nil && check.OK
	}
	result.OK = result.AuthOK
	switch {
	case result.AuthOK:
		result.Message = "public URL reaches this server and bearer auth works"
	case resp.StatusCode == http.StatusOK:
		result.Message = "public URL returned an invalid MicaGo authentication response"
	case resp.StatusCode == http.StatusUnauthorized:
		result.Message = "reached a server but bearer auth was rejected"
	default:
		result.Message = fmt.Sprintf("reached an endpoint but received HTTP %d", resp.StatusCode)
	}
	c.record(reachableYes())
	return result
}

func (c *NetworkController) record(r Reachability) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.lastReachable = r
	c.lastCheckedAt = time.Now().UnixMilli()
}

// GetServerURLs returns all available connection endpoints grouped by type.
func (h *Handlers) GetServerURLs(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, h.buildServerURLs())
}

func (h *Handlers) buildServerURLs() ServerURLsResponse {
	resp := ServerURLsResponse{
		LAN:                      lanEndpoints(h.cfg.HTTPAddr),
		PreferredPairingEndpoint: h.cfg.PreferredPairingEndpoint,
	}
	if resp.PreferredPairingEndpoint == "" {
		resp.PreferredPairingEndpoint = "auto"
	}

	if h.status.Network != nil {
		snap := h.status.Network.snapshot()
		resp.PreferredPairingEndpoint = snap.preferred
		resp.Public = buildPublicEndpoint(snap)
	}
	if h.tlsPort != "" {
		resp.TLSFingerprint = h.tlsFingerprint
		for i := range resp.LAN {
			e := &resp.LAN[i]
			u, _ := url.Parse(e.BaseURL)
			u.Scheme = "https"
			u.Host = net.JoinHostPort(u.Hostname(), h.tlsPort)
			e.BaseURL = u.String()
			e.WSURL = strings.Replace(e.BaseURL, "https://", "wss://", 1) + "/ws"
		}
		if !strings.HasPrefix(resp.Public.BaseURL, "https://") {
			resp.Public = PublicEndpoint{}
		}
	}
	if h.lanVisibility != nil {
		hidden, err := h.lanVisibility.HiddenLANEndpoints(context.Background())
		if err == nil && hidden != nil {
			excluded := map[string]bool{}
			for _, base := range hidden {
				excluded[base] = true
				if h.tlsPort != "" {
					u, parseErr := url.Parse(base)
					if parseErr == nil && u.Scheme == "http" {
						u.Scheme = "https"
						u.Host = net.JoinHostPort(u.Hostname(), h.tlsPort)
						excluded[u.String()] = true
					}
				}
			}
			for i := range resp.LAN {
				value := excluded[resp.LAN[i].BaseURL]
				resp.LAN[i].Hidden = &value
			}
		}
	}
	resp.ConnectionRevision = connectionRevision(resp)
	return resp
}

// connectionRevision is a short stable hash of the connection-relevant fields.
// Stateless: the same settings always yield the same revision, and any LAN/
// Public change yields a new one (C23).
func connectionRevision(resp ServerURLsResponse) string {
	var b strings.Builder
	for _, e := range resp.LAN {
		b.WriteString(e.BaseURL)
		b.WriteByte('|')
		b.WriteString(e.WSURL)
		if e.Hidden != nil {
			if *e.Hidden {
				b.WriteString("|hidden")
			} else {
				b.WriteString("|visible")
			}
		}
		b.WriteByte('\n')
	}
	if resp.Public.Enabled {
		b.WriteString("public:")
		b.WriteString(resp.Public.BaseURL)
		b.WriteByte('|')
		b.WriteString(resp.Public.WSURL)
	}
	sum := sha256.Sum256([]byte(b.String()))
	return hex.EncodeToString(sum[:6]) // 12 hex chars is plenty for a revision
}

func buildPublicEndpoint(snap networkSnapshot) PublicEndpoint {
	if snap.publicBaseURL == "" {
		return PublicEndpoint{Enabled: false, Reachable: reachableUnknown(), VerifyTLS: snap.verifyTLS}
	}
	base := strings.TrimRight(snap.publicBaseURL, "/")
	pe := PublicEndpoint{
		Enabled:      true,
		Kind:         "custom",
		BaseURL:      base,
		WSURL:        config.WebSocketURLFromBase(base),
		Reachable:    snap.lastReachable,
		ProviderHint: inferProviderHint(base),
		VerifyTLS:    snap.verifyTLS,
	}
	if snap.lastCheckedAt > 0 {
		checked := snap.lastCheckedAt
		pe.LastCheckedAt = &checked
	}
	return pe
}

// SetPublicURL handles POST /api/server/public-url.
func (h *Handlers) SetPublicURL(w http.ResponseWriter, r *http.Request) {
	if h.status.Network == nil {
		writeInternalError(w)
		return
	}
	var req struct {
		PublicBaseURL            string `json:"publicBaseUrl"`
		VerifyTLS                *bool  `json:"verifyTls"`
		PreferredPairingEndpoint string `json:"preferredPairingEndpoint"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeBadRequest(w, "invalid JSON body")
		return
	}

	snap := h.status.Network.snapshot()
	verifyTLS := snap.verifyTLS
	if req.VerifyTLS != nil {
		verifyTLS = *req.VerifyTLS
	}
	preferred := strings.TrimSpace(req.PreferredPairingEndpoint)
	if preferred == "" {
		preferred = snap.preferred
	}

	if err := h.status.Network.SetPublicURL(req.PublicBaseURL, verifyTLS, preferred); err != nil {
		writeBadRequest(w, err.Error())
		return
	}
	resp := h.buildServerURLs()
	// C23: tell connected clients their connection candidates changed so they
	// refresh without rescanning a QR. Best-effort; the client also re-checks
	// the revision on its normal reconnect/poll cycle.
	if h.send != nil && h.send.Events != nil {
		_ = h.send.Events.Broadcast(r.Context(), realtime.Event{
			Type: "connection:updated",
			Data: map[string]any{"configRevision": resp.ConnectionRevision},
		})
	}
	writeJSON(w, http.StatusOK, resp)
}

// CheckPublicURL handles POST /api/server/public-url/check.
func (h *Handlers) CheckPublicURL(w http.ResponseWriter, r *http.Request) {
	if h.status.Network == nil {
		writeInternalError(w)
		return
	}
	result := h.status.Network.Check(r.Context())
	writeJSON(w, http.StatusOK, result)
}

// lanEndpoints derives LAN endpoints when the bind address makes the server
// LAN-reachable. A loopback-only bind yields no LAN endpoints.
func lanEndpoints(httpAddr string) []EndpointInfo {
	host, port, loopback, wildcard := classifyHost(httpAddr)
	if loopback {
		return []EndpointInfo{}
	}
	if !wildcard && host != "" {
		// Bound to a specific non-loopback address.
		base := "http://" + net.JoinHostPort(host, port)
		return []EndpointInfo{{
			Kind:      "lan",
			Label:     "LAN",
			BaseURL:   base,
			WSURL:     config.WebSocketURLFromBase(base),
			Reachable: reachableUnknown(),
		}}
	}
	// Wildcard bind: enumerate non-loopback IPv4 interface addresses.
	out := make([]EndpointInfo, 0)
	for _, addr := range lanAddresses(httpAddr) {
		base := "http://" + addr
		out = append(out, EndpointInfo{
			Kind:      "lan",
			Label:     "LAN",
			BaseURL:   base,
			WSURL:     config.WebSocketURLFromBase(base),
			Reachable: reachableUnknown(),
		})
	}
	return out
}

func classifyHost(httpAddr string) (host, port string, loopback, wildcard bool) {
	host, port, err := net.SplitHostPort(httpAddr)
	if err != nil {
		host = strings.Trim(httpAddr, "[]")
		port = "3000"
	}
	if port == "" {
		port = "3000"
	}
	lower := strings.ToLower(strings.Trim(host, "[]"))
	loopback = lower == "127.0.0.1" || lower == "::1" || lower == "localhost"
	wildcard = host == "" || lower == "0.0.0.0" || lower == "::"
	return host, port, loopback, wildcard
}

func inferProviderHint(base string) string {
	host := base
	if u, err := url.Parse(base); err == nil && u.Hostname() != "" {
		host = u.Hostname()
	}
	host = strings.ToLower(host)
	switch {
	case strings.HasSuffix(host, ".trycloudflare.com") || strings.Contains(host, "cfargotunnel"):
		return "cloudflare_tunnel"
	case strings.HasSuffix(host, ".ngrok.io") || strings.HasSuffix(host, ".ngrok-free.app") || strings.HasSuffix(host, ".ngrok.app"):
		return "ngrok"
	case strings.HasSuffix(host, ".ts.net"):
		return "tailscale"
	default:
		return "custom"
	}
}

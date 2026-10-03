package realtime

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"nhooyr.io/websocket"
)

type Hub struct {
	mu      sync.Mutex
	clients map[*websocket.Conn]ClientSession
}

func NewHub() *Hub {
	return &Hub{
		clients: make(map[*websocket.Conn]ClientSession),
	}
}

// ClientSession is an active, authenticated WebSocket connection. It is not the
// push-device registry: it contains only ephemeral connection metadata for the
// companion's privacy-facing Paired Devices view.
type ClientSession struct {
	DeviceID      string `json:"deviceId,omitempty"`
	ID            string `json:"id"`
	ClientName    string `json:"clientName,omitempty"`
	ClientType    string `json:"clientType,omitempty"`
	Platform      string `json:"platform,omitempty"`
	AppVersion    string `json:"appVersion,omitempty"`
	RemoteAddress string `json:"remoteAddress,omitempty"`
	UserAgent     string `json:"userAgent,omitempty"`
	ConnectedAt   int64  `json:"connectedAt"`
	LastSeenAt    int64  `json:"lastSeenAt"`
}

func (h *Hub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	h.ServeAuthorized(w, r, "", func() {})
}

func (h *Hub) ServeAuthorized(w http.ResponseWriter, r *http.Request, deviceID string, admitted func()) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		InsecureSkipVerify: true,
	})
	if err != nil {
		admitted()
		return
	}
	session := sessionFromRequest(r)
	session.DeviceID = deviceID
	h.add(conn, session)
	admitted()
	defer h.remove(conn)
	defer conn.Close(websocket.StatusNormalClosure, "")

	for {
		if _, _, err := conn.Read(r.Context()); err != nil {
			return
		}
		h.touch(conn)
	}
}

func (h *Hub) Broadcast(ctx context.Context, event Event) error {
	payload, err := json.Marshal(event)
	if err != nil {
		return err
	}

	h.mu.Lock()
	clients := make([]*websocket.Conn, 0, len(h.clients))
	for conn := range h.clients {
		clients = append(clients, conn)
	}
	h.mu.Unlock()

	for _, conn := range clients {
		writeCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		err := conn.Write(writeCtx, websocket.MessageText, payload)
		cancel()
		if err != nil {
			h.remove(conn)
			_ = conn.Close(websocket.StatusInternalError, "write failed")
		}
	}

	return nil
}

func (h *Hub) Close() {
	h.mu.Lock()
	clients := make([]*websocket.Conn, 0, len(h.clients))
	for conn := range h.clients {
		clients = append(clients, conn)
	}
	h.clients = make(map[*websocket.Conn]ClientSession)
	h.mu.Unlock()

	for _, conn := range clients {
		_ = conn.Close(websocket.StatusGoingAway, "server shutdown")
	}
}

func (h *Hub) add(conn *websocket.Conn, session ClientSession) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.clients[conn] = session
}

func (h *Hub) remove(conn *websocket.Conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.clients, conn)
}

func (h *Hub) ClientCount() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.clients)
}

func (h *Hub) Clients() []ClientSession {
	h.mu.Lock()
	defer h.mu.Unlock()
	sessions := make([]ClientSession, 0, len(h.clients))
	for _, session := range h.clients {
		sessions = append(sessions, session)
	}
	return sessions
}

func (h *Hub) touch(conn *websocket.Conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	session, ok := h.clients[conn]
	if !ok {
		return
	}
	session.LastSeenAt = time.Now().UnixMilli()
	h.clients[conn] = session
}

func sessionFromRequest(r *http.Request) ClientSession {
	now := time.Now().UnixMilli()
	q := r.URL.Query()
	return ClientSession{
		ID:            newSessionID(),
		ClientName:    firstNonEmpty(q.Get("name"), r.Header.Get("X-MicaGo-Client-Name")),
		ClientType:    firstNonEmpty(q.Get("clientType"), r.Header.Get("X-MicaGo-Client-Type")),
		Platform:      firstNonEmpty(q.Get("platform"), r.Header.Get("X-MicaGo-Platform")),
		AppVersion:    firstNonEmpty(q.Get("appVersion"), r.Header.Get("X-MicaGo-App-Version")),
		RemoteAddress: remoteHost(r),
		UserAgent:     r.UserAgent(),
		ConnectedAt:   now,
		LastSeenAt:    now,
	}
}

func newSessionID() string {
	var b [8]byte
	if _, err := rand.Read(b[:]); err == nil {
		return "ws_" + hex.EncodeToString(b[:])
	}
	return "ws_unknown"
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v = strings.TrimSpace(v); v != "" {
			return v
		}
	}
	return ""
}

func remoteHost(r *http.Request) string {
	host := r.Header.Get("X-Forwarded-For")
	if idx := strings.Index(host, ","); idx >= 0 {
		host = host[:idx]
	}
	if host = strings.TrimSpace(host); host != "" {
		return host
	}
	if h, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		return h
	}
	return strings.TrimSpace(r.RemoteAddr)
}

// DisconnectDevice removes sockets before closing so subsequent broadcasts
// cannot target a revoked device, including sockets that are still handshaking.
func (h *Hub) DisconnectDevice(id string) {
	h.mu.Lock()
	var conns []*websocket.Conn
	for conn, session := range h.clients {
		if session.DeviceID == id {
			conns = append(conns, conn)
			delete(h.clients, conn)
		}
	}
	h.mu.Unlock()
	for _, conn := range conns {
		_ = conn.CloseNow()
	}
}

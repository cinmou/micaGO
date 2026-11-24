package realtime

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

type pipeAddr struct{}

func (pipeAddr) Network() string { return "pipe" }
func (pipeAddr) String() string  { return "127.0.0.1:0" }

type pipeListener struct {
	ch     chan net.Conn
	closed chan struct{}
	once   sync.Once
}

func newPipeListener() *pipeListener {
	return &pipeListener{
		ch:     make(chan net.Conn, 16),
		closed: make(chan struct{}),
	}
}

func (l *pipeListener) Accept() (net.Conn, error) {
	select {
	case c := <-l.ch:
		return c, nil
	case <-l.closed:
		return nil, net.ErrClosed
	}
}

func (l *pipeListener) Close() error {
	l.once.Do(func() { close(l.closed) })
	return nil
}

func (l *pipeListener) Addr() net.Addr { return pipeAddr{} }

func (l *pipeListener) DialContext(_ context.Context, _, _ string) (net.Conn, error) {
	serverConn, clientConn := net.Pipe()
	select {
	case l.ch <- serverConn:
		return clientConn, nil
	case <-l.closed:
		_ = serverConn.Close()
		_ = clientConn.Close()
		return nil, net.ErrClosed
	}
}

func TestHubRegisterUnregisterAndEmptyBroadcast(t *testing.T) {
	hub := NewHub()
	conn1 := &websocket.Conn{}
	conn2 := &websocket.Conn{}

	hub.add(conn1, ClientSession{ID: "one"})
	hub.add(conn2, ClientSession{ID: "two"})

	if hub.ClientCount() != 2 {
		t.Fatalf("expected 2 clients, got %d", hub.ClientCount())
	}
	if sessions := hub.Clients(); len(sessions) != 2 {
		t.Fatalf("expected 2 session snapshots, got %d", len(sessions))
	}

	hub.remove(conn1)
	if hub.ClientCount() != 1 {
		t.Fatalf("expected 1 client after remove, got %d", hub.ClientCount())
	}

	hub.remove(conn2)
	if hub.ClientCount() != 0 {
		t.Fatalf("expected 0 clients after cleanup, got %d", hub.ClientCount())
	}

	if err := hub.Broadcast(context.Background(), Event{Type: "message:new", Data: map[string]any{"guid": "msg-1"}}); err != nil {
		t.Fatalf("expected empty broadcast to succeed, got %v", err)
	}
}

func TestHubConcurrentBroadcastAddRemoveAndDisconnect(t *testing.T) {
	hub := NewHub()
	defer hub.Close()

	ln := newPipeListener()
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hub.ServeAuthorized(w, r, r.URL.Query().Get("device"), func() {})
	}))
	srv.Listener = ln
	srv.Start()
	defer srv.Close()

	httpClient := &http.Client{
		Transport: &http.Transport{
			DialContext: ln.DialContext,
		},
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	const clientCount = 4
	conns := make([]*websocket.Conn, 0, clientCount)
	for i := 0; i < clientCount; i++ {
		deviceID := "dev-keep"
		if i == 0 {
			deviceID = "dev-revoke"
		}
		c, _, err := websocket.Dial(ctx, "ws://pipe/ws?device="+deviceID, &websocket.DialOptions{HTTPClient: httpClient})
		if err != nil {
			t.Fatalf("dial client %d: %v", i, err)
		}
		conns = append(conns, c)
		defer c.CloseNow()
	}

	// Drain client reads so Broadcast writes complete without blocking.
	var readerWG sync.WaitGroup
	for _, c := range conns {
		readerWG.Add(1)
		go func(conn *websocket.Conn) {
			defer readerWG.Done()
			for {
				if _, _, err := conn.Read(ctx); err != nil {
					return
				}
			}
		}(c)
	}

	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			for j := 0; j < 10; j++ {
				if err := hub.Broadcast(ctx, Event{Type: "message:new", Data: map[string]any{"n": idx*10 + j}}); err != nil {
					t.Errorf("broadcast failed: %v", err)
				}
			}
		}(i)
	}

	wg.Add(1)
	go func() {
		defer wg.Done()
		hub.DisconnectDevice("dev-revoke")
		_ = hub.Clients()
		_ = hub.ClientCount()
	}()

	wg.Wait()
	hub.Close()
	cancel()
	readerWG.Wait()
}

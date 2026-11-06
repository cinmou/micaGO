package notify

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"micagoserver/internal/store"
)

// TestWebPushLiveNtfy sends a real encrypted push through an ntfy server acting
// as a UnifiedPush distributor, reads it back the way the ntfy app would, and
// decrypts it with the subscriber key. Opt-in, needs network:
//
//	MICAGO_WEBPUSH_E2E_NTFY=https://ntfy.sh go test ./internal/notify -run LiveNtfy -v
func TestWebPushLiveNtfy(t *testing.T) {
	base := strings.TrimRight(os.Getenv("MICAGO_WEBPUSH_E2E_NTFY"), "/")
	if base == "" {
		t.Skip("set MICAGO_WEBPUSH_E2E_NTFY to an ntfy base URL")
	}
	rnd := make([]byte, 6)
	rand.Read(rnd)
	// ntfy only treats "up" + 12 characters as a UnifiedPush topic.
	topic := "up" + hex.EncodeToString(rnd)
	sub := newTestSubscriber(t)
	token := sub.token(base + "/" + topic + "?up=1")

	// Subscribe first, like the ntfy app does: ntfy refuses UnifiedPush
	// publishes to topics with no active subscriber.
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, base+"/"+topic+"/json", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	provider := NewWebPushProvider(testVAPIDKey(t), "https://github.com/cinmou/micaGO", nil, time.Hour, nil)
	notification := Notification{Type: "test", Title: "micaGO UnifiedPush demo", Body: "端到端加密 ✓ " + time.Now().Format(time.RFC3339), PreviewMode: "sender_and_text"}
	go func() {
		time.Sleep(time.Second) // let the subscription register
		if err := provider.Send(ctx, store.DeviceRecord{ID: "live", PushToken: &token}, notification); err != nil {
			t.Errorf("send: %v", err)
			cancel()
		}
	}()

	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 64*1024), 64*1024)
	for scanner.Scan() {
		var msg struct {
			Event    string `json:"event"`
			Message  string `json:"message"`
			Encoding string `json:"encoding"`
		}
		if json.Unmarshal(scanner.Bytes(), &msg) != nil || msg.Event != "message" {
			continue
		}
		t.Logf("ntfy stored: encoding=%q, %d chars (ciphertext only)", msg.Encoding, len(msg.Message))
		if strings.Contains(msg.Message, "micaGO") {
			t.Fatal("ntfy saw plaintext")
		}
		raw := []byte(msg.Message)
		if msg.Encoding == "base64" {
			if raw, err = base64.StdEncoding.DecodeString(msg.Message); err != nil {
				t.Fatal(err)
			}
		}
		plain, err := decryptWebPushForTest(raw, sub.private, sub.auth)
		if err != nil {
			t.Fatal(err)
		}
		t.Logf("subscriber decrypted: %s", plain)
		var data map[string]string
		if err := json.Unmarshal(plain, &data); err != nil || data["title"] != notification.Title || data["body"] != notification.Body {
			t.Fatalf("decrypted data = %v (%v)", data, err)
		}
		return
	}
	t.Fatal("no message found on ntfy topic")
}

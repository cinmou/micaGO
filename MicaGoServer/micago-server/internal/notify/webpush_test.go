package notify

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"micagoserver/internal/store"
)

func mustB64(t *testing.T, s string) []byte {
	t.Helper()
	b, err := decodeBase64URL(strings.Join(strings.Fields(s), ""))
	if err != nil {
		t.Fatalf("decode %q: %v", s, err)
	}
	return b
}

// RFC 8291 Section 5 / Appendix A test vector.
func TestEncryptWebPushMatchesRFC8291Vector(t *testing.T) {
	asPrivate, err := ecdh.P256().NewPrivateKey(mustB64(t, "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"))
	if err != nil {
		t.Fatal(err)
	}
	uaPublic, err := ecdh.P256().NewPublicKey(mustB64(t, "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"))
	if err != nil {
		t.Fatal(err)
	}
	got, err := encryptWebPush(
		[]byte("When I grow up, I want to be a watermelon"),
		uaPublic,
		mustB64(t, "BTBZMqHH6r4Tts7J_aSIgg"),
		asPrivate,
		mustB64(t, "DGv6ra1nlYgDCS1FRnbzlw"),
	)
	if err != nil {
		t.Fatal(err)
	}
	want := append(
		mustB64(t, "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"),
		mustB64(t, "8pfeW0KbunFT06SuDKoJH9Ql87S1QUrdirN6GcG7sFz1y1sqLgVi1VhjVkHsUoEsbI_0LpXMuGvnzQ")...,
	)
	if !bytes.Equal(got, want) {
		t.Fatalf("ciphertext mismatch\n got %s\nwant %s",
			base64.RawURLEncoding.EncodeToString(got), base64.RawURLEncoding.EncodeToString(want))
	}
	plain, err := decryptWebPushForTest(got, mustUAPrivate(t, "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"), mustB64(t, "BTBZMqHH6r4Tts7J_aSIgg"))
	if err != nil || string(plain) != "When I grow up, I want to be a watermelon" {
		t.Fatalf("decrypt = %q, %v", plain, err)
	}
}

func mustUAPrivate(t *testing.T, s string) *ecdh.PrivateKey {
	t.Helper()
	key, err := ecdh.P256().NewPrivateKey(mustB64(t, s))
	if err != nil {
		t.Fatal(err)
	}
	return key
}

// decryptWebPushForTest is the user-agent side of RFC 8291 (what the
// UnifiedPush connector does on the phone).
func decryptWebPushForTest(body []byte, uaPrivate *ecdh.PrivateKey, authSecret []byte) ([]byte, error) {
	if len(body) < 21 {
		return nil, errors.New("short body")
	}
	salt := body[:16]
	idLen := int(body[20])
	if len(body) < 21+idLen {
		return nil, errors.New("short key id")
	}
	_ = binary.BigEndian.Uint32(body[16:20])
	asPublic, err := ecdh.P256().NewPublicKey(body[21 : 21+idLen])
	if err != nil {
		return nil, err
	}
	ciphertext := body[21+idLen:]
	secret, err := uaPrivate.ECDH(asPublic)
	if err != nil {
		return nil, err
	}
	keyInfo := append([]byte("WebPush: info\x00"), uaPrivate.PublicKey().Bytes()...)
	keyInfo = append(keyInfo, asPublic.Bytes()...)
	ikm, _ := hkdf.Key(sha256.New, secret, authSecret, string(keyInfo), 32)
	prk, _ := hkdf.Extract(sha256.New, ikm, salt)
	cek, _ := hkdf.Expand(sha256.New, prk, "Content-Encoding: aes128gcm\x00", 16)
	nonce, _ := hkdf.Expand(sha256.New, prk, "Content-Encoding: nonce\x00", 12)
	block, _ := aes.NewCipher(cek)
	gcm, _ := cipher.NewGCM(block)
	plain, err := gcm.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return nil, err
	}
	plain = bytes.TrimRight(plain, "\x00")
	if len(plain) == 0 || plain[len(plain)-1] != 0x02 {
		return nil, errors.New("missing last-record delimiter")
	}
	return plain[:len(plain)-1], nil
}

type testSubscriber struct {
	private *ecdh.PrivateKey
	auth    []byte
}

func newTestSubscriber(t *testing.T) testSubscriber {
	t.Helper()
	key, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	auth := make([]byte, 16)
	rand.Read(auth)
	return testSubscriber{private: key, auth: auth}
}

func (s testSubscriber) token(endpoint string) string {
	raw, _ := json.Marshal(map[string]string{
		"endpoint": endpoint,
		"p256dh":   base64.RawURLEncoding.EncodeToString(s.private.PublicKey().Bytes()),
		"auth":     base64.RawURLEncoding.EncodeToString(s.auth),
	})
	return string(raw)
}

func testVAPIDKey(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	key, err := LoadOrCreateVAPIDKey(filepath.Join(t.TempDir(), "vapid_private_key.pem"))
	if err != nil {
		t.Fatal(err)
	}
	return key
}

func verifyVAPIDHeader(t *testing.T, header string, key *ecdsa.PrivateKey, wantAud string) {
	t.Helper()
	if !strings.HasPrefix(header, "vapid t=") {
		t.Fatalf("authorization = %q", header)
	}
	parts := strings.SplitN(strings.TrimPrefix(header, "vapid t="), ", k=", 2)
	if len(parts) != 2 {
		t.Fatalf("authorization = %q", header)
	}
	wantK, _ := VAPIDPublicKey(key)
	if parts[1] != wantK {
		t.Fatalf("k = %q, want %q", parts[1], wantK)
	}
	segments := strings.Split(parts[0], ".")
	if len(segments) != 3 {
		t.Fatalf("jwt = %q", parts[0])
	}
	var claims struct {
		Aud string `json:"aud"`
		Exp int64  `json:"exp"`
		Sub string `json:"sub"`
	}
	if err := json.Unmarshal(mustB64(t, segments[1]), &claims); err != nil {
		t.Fatal(err)
	}
	if claims.Aud != wantAud || claims.Sub == "" || claims.Exp <= time.Now().Unix() {
		t.Fatalf("claims = %+v", claims)
	}
	sig := mustB64(t, segments[2])
	digest := sha256.Sum256([]byte(segments[0] + "." + segments[1]))
	r, s := new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])
	if !ecdsa.Verify(&key.PublicKey, digest[:], r, s) {
		t.Fatal("VAPID signature does not verify")
	}
}

func TestWebPushProviderSendsEncryptedSignedPush(t *testing.T) {
	sub := newTestSubscriber(t)
	key := testVAPIDKey(t)
	var gotBody []byte
	var gotHeader http.Header
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotHeader = r.Header.Clone()
		gotBody, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusCreated)
	}))
	defer server.Close()

	provider := NewWebPushProvider(key, "mailto:test@example.com", server.Client(), time.Hour, nil)
	token := sub.token(server.URL + "/upAbC?up=1")
	err := provider.Send(context.Background(), store.DeviceRecord{ID: "d1", PushProvider: "unifiedpush", PushToken: &token}, Notification{
		Type: "message:new", Title: "Alice", Body: "你好 watermelon", ChatGUID: "chat-1", PreviewMode: "sender_and_text",
	})
	if err != nil {
		t.Fatal(err)
	}
	if gotHeader.Get("Content-Encoding") != "aes128gcm" || gotHeader.Get("TTL") != "3600" || gotHeader.Get("Urgency") != "high" {
		t.Fatalf("headers = %v", gotHeader)
	}
	verifyVAPIDHeader(t, gotHeader.Get("Authorization"), key, server.URL)
	if bytes.Contains(gotBody, []byte("watermelon")) {
		t.Fatal("push body contains plaintext")
	}
	plain, err := decryptWebPushForTest(gotBody, sub.private, sub.auth)
	if err != nil {
		t.Fatal(err)
	}
	var data map[string]string
	if err := json.Unmarshal(plain, &data); err != nil {
		t.Fatal(err)
	}
	if data["title"] != "Alice" || data["body"] != "你好 watermelon" || data["chatGuid"] != "chat-1" || data["type"] != "message:new" {
		t.Fatalf("data = %v", data)
	}
}

func TestWebPushProviderPrunesGoneSubscription(t *testing.T) {
	sub := newTestSubscriber(t)
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusGone)
	}))
	defer server.Close()
	pruned := ""
	provider := NewWebPushProvider(testVAPIDKey(t), "mailto:test@example.com", server.Client(), time.Hour, func(id string) { pruned = id })
	token := sub.token(server.URL + "/gone")
	if err := provider.Send(context.Background(), store.DeviceRecord{ID: "dead", PushToken: &token}, Notification{Type: "test"}); err != nil {
		t.Fatal(err)
	}
	if pruned != "dead" {
		t.Fatalf("pruned = %q", pruned)
	}
}

func TestWebPushProviderDoesNotFollowRedirects(t *testing.T) {
	sub := newTestSubscriber(t)
	hits := 0
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		http.Redirect(w, r, "/elsewhere", http.StatusTemporaryRedirect)
	}))
	defer server.Close()
	provider := NewWebPushProvider(testVAPIDKey(t), "mailto:test@example.com", server.Client(), time.Hour, nil)
	token := sub.token(server.URL + "/start")
	err := provider.Send(context.Background(), store.DeviceRecord{ID: "d", PushToken: &token}, Notification{Type: "test"})
	if err == nil || hits != 1 {
		t.Fatalf("err = %v, hits = %d", err, hits)
	}
}

func TestWebPushErrorsDoNotLeakEndpointPath(t *testing.T) {
	sub := newTestSubscriber(t)
	provider := NewWebPushProvider(testVAPIDKey(t), "mailto:test@example.com", &http.Client{Timeout: time.Second}, time.Hour, nil)
	token := sub.token("https://127.0.0.1:1/secret-topic-abc?up=1")
	err := provider.Send(context.Background(), store.DeviceRecord{ID: "d", PushToken: &token}, Notification{Type: "test"})
	if err == nil {
		t.Fatal("expected connection error")
	}
	if strings.Contains(err.Error(), "secret-topic-abc") {
		t.Fatalf("error leaks endpoint: %v", err)
	}
}

func TestWebPushDropsBodyWhenRecordWouldOverflow(t *testing.T) {
	sub := newTestSubscriber(t)
	provider := NewWebPushProvider(testVAPIDKey(t), "mailto:test@example.com", nil, time.Hour, nil)
	parsed, err := ParseWebPushSubscription(sub.token("https://push.example/x"))
	if err != nil {
		t.Fatal(err)
	}
	// Control characters expand 6x under JSON escaping.
	body, err := provider.encryptNotification(parsed, Notification{Type: "message:new", Title: "T", Body: strings.Repeat("\x01", 1500)})
	if err != nil {
		t.Fatal(err)
	}
	if len(body) > webPushMaxBody {
		t.Fatalf("body is %d bytes", len(body))
	}
	plain, err := decryptWebPushForTest(body, sub.private, sub.auth)
	if err != nil {
		t.Fatal(err)
	}
	var data map[string]string
	json.Unmarshal(plain, &data)
	if _, ok := data["body"]; ok || data["title"] != "T" {
		t.Fatalf("data = %v", data)
	}
}

func TestParseWebPushSubscriptionRejectsUnsafeInput(t *testing.T) {
	sub := newTestSubscriber(t)
	cases := map[string]string{
		"http endpoint":  sub.token("http://ntfy.example/up?up=1"),
		"file endpoint":  sub.token("file:///etc/passwd"),
		"userinfo":       sub.token("https://user:pw@ntfy.example/up"),
		"not json":       "fcm-token-abc",
		"bad key":        `{"endpoint":"https://x.example/a","p256dh":"AAAA","auth":"BTBZMqHH6r4Tts7J_aSIgg"}`,
		"short auth":     `{"endpoint":"https://x.example/a","p256dh":"BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4","auth":"AAAA"}`,
		"missing fields": `{}`,
	}
	for name, token := range cases {
		if _, err := ParseWebPushSubscription(token); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	// Standard base64 with padding is accepted (client libraries differ).
	std := `{"endpoint":"https://fcm.googleapis.com/fcm/send/abc","p256dh":"` +
		base64.StdEncoding.EncodeToString(sub.private.PublicKey().Bytes()) + `","auth":"` +
		base64.StdEncoding.EncodeToString(sub.auth) + `"}`
	parsed, err := ParseWebPushSubscription(std)
	if err != nil || parsed.EndpointHost() != "fcm.googleapis.com" {
		t.Fatalf("std base64: %v %q", err, parsed.EndpointHost())
	}
}

func TestLoadOrCreateVAPIDKeyPersistsPrivately(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "vapid_private_key.pem")
	first, err := LoadOrCreateVAPIDKey(path)
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v", info.Mode().Perm())
	}
	second, err := LoadOrCreateVAPIDKey(path)
	if err != nil {
		t.Fatal(err)
	}
	a, _ := VAPIDPublicKey(first)
	b, _ := VAPIDPublicKey(second)
	if a != b || len(mustB64(t, a)) != 65 {
		t.Fatalf("public keys %q vs %q", a, b)
	}
	if err := os.WriteFile(path, []byte("garbage"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadOrCreateVAPIDKey(path); err == nil {
		t.Fatal("corrupt key accepted (must not be silently regenerated)")
	}
}

func TestTruncateUTF8KeepsRuneBoundary(t *testing.T) {
	if got := truncateUTF8("你好", 4); got != "你" {
		t.Fatalf("got %q", got)
	}
	if got := truncateUTF8("abc", 10); got != "abc" {
		t.Fatalf("got %q", got)
	}
}

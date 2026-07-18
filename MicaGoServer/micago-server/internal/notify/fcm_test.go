package notify

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"micagoserver/internal/store"
)

func testServiceAccountJSON(t *testing.T) []byte {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	pemBytes := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	sa := map[string]string{
		"type":           "service_account",
		"project_id":     "demo-project",
		"private_key_id": "kid123",
		"private_key":    string(pemBytes),
		"client_email":   "svc@demo-project.iam.gserviceaccount.com",
		"token_uri":      "https://oauth2.googleapis.com/token",
	}
	data, _ := json.Marshal(sa)
	return data
}

func TestParseServiceAccount(t *testing.T) {
	sa, err := ParseServiceAccount(testServiceAccountJSON(t))
	if err != nil {
		t.Fatalf("valid SA should parse: %v", err)
	}
	if sa.ClientEmail == "" || sa.ProjectID != "demo-project" {
		t.Fatalf("unexpected SA: %+v", sa)
	}

	if _, err := ParseServiceAccount([]byte(`{"type":"service_account"}`)); err == nil {
		t.Fatalf("SA without key/email should fail")
	}
	if _, err := ParseServiceAccount([]byte(`{"client_email":"x","private_key":"not-pem"}`)); err == nil {
		t.Fatalf("SA with bad key should fail")
	}
}

func TestSignedAssertionHasThreeSegments(t *testing.T) {
	sa, err := ParseServiceAccount(testServiceAccountJSON(t))
	if err != nil {
		t.Fatal(err)
	}
	ts := NewTokenSource(sa, nil, scopeFCM, scopeFirestore)
	jwt, err := ts.signedAssertion(time.Now())
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	if parts := strings.Split(jwt, "."); len(parts) != 3 {
		t.Fatalf("expected 3 JWT segments, got %d", len(parts))
	}
}

func TestFCMMessagePayloadIsDataOnly(t *testing.T) {
	n := Notification{
		Type: "message:new", MessageGUID: "g1", ChatGUID: "c1",
		Title: "Jane", Body: "hi", SenderName: "Jane",
		ConversationTitle: "Jane", Handle: "+15550001",
		PreviewMode: "sender_and_text", HasAttachments: true, CreatedAt: 123,
	}
	msg := fcmMessage("dev-token", n, 24*time.Hour)
	inner := msg["message"].(map[string]any)
	if inner["token"] != "dev-token" {
		t.Fatalf("token not set")
	}
	data := inner["data"].(map[string]string)
	if data["title"] != "Jane" || data["body"] != "hi" || data["chatGuid"] != "c1" {
		t.Fatalf("unexpected data payload: %+v", data)
	}
	if _, ok := inner["notification"]; ok {
		t.Fatalf("FCM payload must be data-only; got notification block: %+v", inner["notification"])
	}
	// C31: the raw sender handle is carried so the client can fall back to it and
	// resolve it on-device (the handle is already part of the message API).
	if data["handle"] != "+15550001" {
		t.Fatalf("expected handle in payload, got %q", data["handle"])
	}
	if data["senderName"] != "Jane" || data["conversationTitle"] != "Jane" || data["isGroup"] != "false" {
		t.Fatalf("unexpected conversation fields: %+v", data)
	}
	if data["hasAttachments"] != "true" {
		t.Fatalf("expected attachment metadata in payload, got %+v", data)
	}
	android := inner["android"].(map[string]any)
	if android["priority"] != "HIGH" {
		t.Fatalf("expected high-priority data push, got %v", android["priority"])
	}
	if android["ttl"] != "86400s" {
		t.Fatalf("expected 24h ttl, got %v", android["ttl"])
	}
	if _, ok := android["notification"]; ok {
		t.Fatalf("android config must not include notification block: %+v", android["notification"])
	}
	// Only the intentional, minimal string fields are present — no tokens, no
	// contact book, no message history.
	for k := range data {
		switch k {
		case "type", "messageGuid", "chatGuid", "sourceRowId", "title", "body", "senderName", "conversationTitle", "isGroup", "handle", "previewMode", "hasAttachments", "createdAt":
		default:
			t.Fatalf("unexpected data key %q", k)
		}
	}
}

func TestClassifyFCMResponse(t *testing.T) {
	if classifyFCMResponse(200, []byte(`{}`)) != fcmOK {
		t.Fatalf("200 should be ok")
	}
	if classifyFCMResponse(404, []byte(`{"error":{"status":"NOT_FOUND"}}`)) != fcmPrune {
		t.Fatalf("404 should prune")
	}
	if classifyFCMResponse(400, []byte(`{"error":{"details":[{"errorCode":"UNREGISTERED"}]}}`)) != fcmPrune {
		t.Fatalf("UNREGISTERED should prune")
	}
	if classifyFCMResponse(400, []byte(`message is too big`)) != fcmTooLarge {
		t.Fatalf("too big should be tolerated")
	}
	if classifyFCMResponse(500, []byte(`internal`)) != fcmError {
		t.Fatalf("500 should be error")
	}
}

func TestSummarizeFCMPermissionError(t *testing.T) {
	body := []byte(`{
		"error": {
			"code": 403,
			"message": "Permission 'cloudmessaging.messages.create' denied on resource '//cloudresourcemanager.googleapis.com/projects/533134841413'",
			"status": "PERMISSION_DENIED"
		}
	}`)
	summary := summarizeFCMError(http.StatusForbidden, body)
	if !strings.Contains(summary, "Firebase Cloud Messaging API Admin") {
		t.Fatalf("expected actionable IAM summary, got %q", summary)
	}
	if strings.Contains(summary, "cloudresourcemanager.googleapis.com/projects") {
		t.Fatalf("expected raw Google resource to be hidden, got %q", summary)
	}
}

type stubTokens struct{}

func (stubTokens) Token(context.Context) (string, error) { return "access-token", nil }

func TestFCMSendPrunesUnregisteredToken(t *testing.T) {
	var pruned string
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: 404,
			Body:       io.NopCloser(strings.NewReader(`{"error":{"status":"UNREGISTERED"}}`)),
			Header:     make(http.Header),
		}, nil
	})}
	p := NewFCMProvider("demo", stubTokens{}, client, time.Hour, func(id string) { pruned = id })

	tok := "dead-token"
	device := store.DeviceRecord{ID: "dev-1", PushProvider: "fcm", PushEnabled: true, PushToken: &tok}
	if err := p.Send(context.Background(), device, Notification{Type: "test"}); err != nil {
		t.Fatalf("prune path should not error, got %v", err)
	}
	if pruned != "dev-1" {
		t.Fatalf("expected device dev-1 pruned, got %q", pruned)
	}
}

func TestFCMSendNoTokenIsNotConfigured(t *testing.T) {
	p := NewFCMProvider("demo", stubTokens{}, &http.Client{}, time.Hour, nil)
	device := store.DeviceRecord{ID: "dev-1", PushProvider: "fcm", PushEnabled: true}
	if err := p.Send(context.Background(), device, Notification{}); err != ErrPushNotConfigured {
		t.Fatalf("expected ErrPushNotConfigured, got %v", err)
	}
}

package notify

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"micagoserver/internal/store"
)

// fcmMaxBodyChars caps the preview text placed in a push so we stay well under
// FCM's ~4KB data-payload limit.
const fcmMaxBodyChars = 1500

// tokenProvider is the OAuth2 token interface (satisfied by *TokenSource);
// kept as an interface so tests can stub it.
type tokenProvider interface {
	Token(ctx context.Context) (string, error)
}

// FCMProvider delivers notifications via the FCM HTTP v1 API using the user's
// own Firebase project (self-host). Push tokens are sent to Google as delivery
// addresses only; nothing is stored in any cloud here.
type FCMProvider struct {
	projectID string
	tokens    tokenProvider
	client    *http.Client
	ttl       time.Duration
	// prune is called with a device ID when its push token is rejected as
	// permanently invalid (UNREGISTERED). May be nil.
	prune func(deviceID string)
}

func NewFCMProvider(projectID string, tokens tokenProvider, client *http.Client, ttl time.Duration, prune func(string)) *FCMProvider {
	if client == nil {
		client = &http.Client{Timeout: 15 * time.Second}
	}
	if ttl <= 0 {
		ttl = 24 * time.Hour
	}
	return &FCMProvider{projectID: projectID, tokens: tokens, client: client, ttl: ttl, prune: prune}
}

func (p *FCMProvider) Name() string { return "fcm" }

func (p *FCMProvider) Send(ctx context.Context, device store.DeviceRecord, notification Notification) error {
	if device.PushToken == nil || strings.TrimSpace(*device.PushToken) == "" {
		return ErrPushNotConfigured
	}
	accessToken, err := p.tokens.Token(ctx)
	if err != nil {
		return fmt.Errorf("fcm token: %w", err)
	}

	payload := fcmMessage(*device.PushToken, notification, p.ttl)
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	url := fmt.Sprintf("https://fcm.googleapis.com/v1/projects/%s/messages:send", p.projectID)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("Content-Type", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		return fmt.Errorf("fcm send: %w", err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))

	switch classifyFCMResponse(resp.StatusCode, respBody) {
	case fcmOK:
		return nil
	case fcmPrune:
		if p.prune != nil {
			p.prune(device.ID)
		}
		return nil // handled: dead token removed, not an error to surface
	case fcmTooLarge:
		// Already truncated proactively; treat as non-fatal so one oversized
		// message doesn't fail the whole dispatch.
		return nil
	default:
		return fmt.Errorf("fcm send failed: %s", summarizeFCMError(resp.StatusCode, respBody))
	}
}

// fcmMessage builds the FCM HTTP v1 request body. Only the gated Notification
// fields are sent as string data; no contacts, tokens, or history.
func fcmMessage(deviceToken string, n Notification, ttl time.Duration) map[string]any {
	body := n.Body
	if len(body) > fcmMaxBodyChars {
		body = body[:fcmMaxBodyChars]
	}
	data := map[string]string{
		"type":              n.Type,
		"messageGuid":       n.MessageGUID,
		"chatGuid":          n.ChatGUID,
		"sourceRowId":       strconv.FormatInt(n.SourceRowID, 10),
		"title":             n.Title,
		"body":              body,
		"senderName":        n.SenderName,
		"conversationTitle": n.ConversationTitle,
		"isGroup":           strconv.FormatBool(n.IsGroup),
		"handle":            n.Handle,
		"previewMode":       n.PreviewMode,
		"createdAt":         strconv.FormatInt(n.CreatedAt, 10),
	}
	return map[string]any{
		"message": map[string]any{
			"token": deviceToken,
			"data":  data,
			"android": map[string]any{
				"priority": "HIGH",
				"ttl":      strconv.FormatInt(int64(ttl/time.Second), 10) + "s",
			},
		},
	}
}

type fcmOutcome int

const (
	fcmOK fcmOutcome = iota
	fcmPrune
	fcmTooLarge
	fcmError
)

// classifyFCMResponse interprets an FCM HTTP v1 response: 2xx ok; UNREGISTERED /
// invalid-token → prune; payload-too-large → tolerate; otherwise error.
func classifyFCMResponse(status int, body []byte) fcmOutcome {
	if status >= 200 && status < 300 {
		return fcmOK
	}
	lower := strings.ToLower(string(body))
	if strings.Contains(lower, "unregistered") ||
		strings.Contains(lower, "registration-token-not-registered") ||
		(status == http.StatusNotFound) {
		return fcmPrune
	}
	if strings.Contains(lower, "too big") || strings.Contains(lower, "payload") && strings.Contains(lower, "size") ||
		strings.Contains(lower, "message is too big") {
		return fcmTooLarge
	}
	return fcmError
}

func summarizeFCMError(status int, body []byte) string {
	type googleError struct {
		Error struct {
			Message string `json:"message"`
			Status  string `json:"status"`
		} `json:"error"`
	}
	var parsed googleError
	if err := json.Unmarshal(body, &parsed); err == nil {
		message := strings.TrimSpace(parsed.Error.Message)
		statusText := strings.TrimSpace(parsed.Error.Status)
		lower := strings.ToLower(message)
		if status == http.StatusForbidden && strings.Contains(lower, "cloudmessaging.messages.create") {
			return "service account is missing the Firebase Cloud Messaging API Admin permission (cloudmessaging.messages.create)"
		}
		if message != "" {
			if statusText != "" {
				return fmt.Sprintf("HTTP %d %s: %s", status, statusText, message)
			}
			return fmt.Sprintf("HTTP %d: %s", status, message)
		}
	}
	text := strings.TrimSpace(string(body))
	if text == "" {
		return fmt.Sprintf("HTTP %d", status)
	}
	if len(text) > 500 {
		text = text[:500] + "..."
	}
	return fmt.Sprintf("HTTP %d: %s", status, text)
}

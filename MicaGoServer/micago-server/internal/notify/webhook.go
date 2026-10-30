package notify

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"micagoserver/internal/store"
)

type WebhookProvider struct {
	URL    string
	Client *http.Client
}

func (p WebhookProvider) Send(ctx context.Context, device store.DeviceRecord, notification Notification) error {
	if p.URL == "" {
		return ErrPushNotConfigured
	}
	payload := map[string]any{
		"device": map[string]any{
			"id":           device.ID,
			"name":         device.Name,
			"platform":     device.Platform,
			"clientType":   device.ClientType,
			"pushProvider": device.PushProvider,
		},
		"notification": notification,
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	client := p.Client
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.URL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("webhook returned status %d", resp.StatusCode)
	}
	return nil
}

package httpapi

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"micagoserver/internal/config"
	"micagoserver/internal/notify"
)

func TestNotificationConfigFailureHidesCredentialPath(t *testing.T) {
	h, _ := newActionHandlers(nil)
	h.SetNotificationConfigurator(notify.NewDispatcher(config.Config{}))
	privatePath := filepath.Join(t.TempDir(), "private-credential.json")
	body, _ := json.Marshal(notificationsConfigRequest{FCMEnabled: true, Provider: "fcm", Preview: "none", ServiceAccountPath: privatePath})
	r := httptest.NewRequest(http.MethodPost, "/api/server/notifications", bytes.NewReader(body))
	w := httptest.NewRecorder()
	h.PutNotificationsConfig(w, r)
	if w.Code != 400 {
		t.Fatalf("unexpected status: %d", w.Code)
	}
	if strings.Contains(w.Body.String(), privatePath) || strings.Contains(w.Body.String(), "private-credential.json") {
		t.Fatal("credential path leaked in response")
	}
}

func TestRemovedPushProvidersAreRejected(t *testing.T) {
	for _, provider := range []string{"hms", "harmony_push", "ntfy"} {
		t.Run(provider, func(t *testing.T) {
			h, _ := newActionHandlers(nil)
			h.SetNotificationConfigurator(notify.NewDispatcher(config.Config{}))
			body, _ := json.Marshal(notificationsConfigRequest{Provider: provider, Preview: "sender"})
			w := httptest.NewRecorder()
			h.PutNotificationsConfig(w, httptest.NewRequest(http.MethodPost, "/api/server/notifications", bytes.NewReader(body)))
			if w.Code != http.StatusBadRequest {
				t.Fatalf("notification configuration accepted removed provider: HTTP %d", w.Code)
			}
			body, _ = json.Marshal(deviceRegisterRequest{Name: "Device", Platform: "android", ClientType: "flutter", PushProvider: provider})
			w = httptest.NewRecorder()
			h.RegisterDevice(w, httptest.NewRequest(http.MethodPost, "/api/devices/register", bytes.NewReader(body)))
			if w.Code != http.StatusBadRequest {
				t.Fatalf("device registration accepted removed provider: HTTP %d", w.Code)
			}
		})
	}
}

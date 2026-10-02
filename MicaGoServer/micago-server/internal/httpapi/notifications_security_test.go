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

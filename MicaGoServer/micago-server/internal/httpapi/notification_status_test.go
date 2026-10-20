package httpapi

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"micagoserver/internal/config"
	"micagoserver/internal/notify"
)

func TestFCMStatusTracksClientFileAvailability(t *testing.T) {
	path := filepath.Join(t.TempDir(), "google-services.json")
	h := &Handlers{cfg: config.Config{FCM: config.FCMConfig{GoogleServicesPath: path}}}
	check := func(want bool) {
		t.Helper()
		if got := h.notificationStatus().FCMClientConfigured; got != want {
			t.Fatalf("client configuration status = %v, want %v", got, want)
		}
		rec := httptest.NewRecorder()
		h.GetFCMClientConfig(rec, httptest.NewRequest(http.MethodGet, "/api/fcm/client", nil))
		var response struct {
			Data notify.FirebaseClientConfig `json:"data"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
			t.Fatal(err)
		}
		if response.Data.Configured != want {
			t.Fatalf("client endpoint disagrees with status: %v, want %v", response.Data.Configured, want)
		}
	}
	check(false)
	for _, content := range []string{`invalid`, `{}`, `{"client":[{}]}`} {
		if err := os.WriteFile(path, []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
		check(false)
	}
	content := `{"project_info":{"project_id":"demo","project_number":"123"},"client":[{"client_info":{"mobilesdk_app_id":"1:123:android:abc"},"api_key":[{"current_key":"test-key"}]}]}`
	if err := os.WriteFile(path, []byte(content), 0600); err != nil {
		t.Fatal(err)
	}
	check(true)
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	check(false)
}

func TestDisablingFCMPreservesFilesUntilExplicitClear(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cfg, err := config.Load(config.Options{})
	if err != nil {
		t.Fatal(err)
	}
	update := config.NotificationsUpdate{
		Provider: "none", Preview: "sender", FCMProjectID: "saved-project",
		ServiceAccountPath: filepath.Join(t.TempDir(), "service.json"),
		GoogleServicesPath: filepath.Join(t.TempDir(), "client.json"),
		PublicURLSync:      true,
	}
	if err := config.UpdateNotificationsConfig(cfg.ConfigPath, update); err != nil {
		t.Fatal(err)
	}
	cfg, err = config.Load(config.Options{})
	if err != nil {
		t.Fatal(err)
	}
	h := &Handlers{cfg: cfg}
	h.SetNotificationConfigurator(notify.NewDispatcher(cfg))
	status := h.notificationStatus()
	if status.FCMEnabled || status.FCMProjectID != "saved-project" || !status.PublicURLSync {
		t.Fatal("status must expose the saved form settings independently of provider availability")
	}
	if status.FCMServiceAccountConfigured || status.FCMClientConfigured {
		t.Fatal("missing credential/configuration files must not report ready")
	}
	post := func(clear bool) {
		t.Helper()
		body, err := json.Marshal(notificationsConfigRequest{Provider: "none", Preview: "sender", FCMProjectID: "saved-project", PublicURLSync: true, ClearFirebaseConfig: clear})
		if err != nil {
			t.Fatal(err)
		}
		rec := httptest.NewRecorder()
		h.PutNotificationsConfig(rec, httptest.NewRequest(http.MethodPost, "/api/server/notifications", bytes.NewReader(body)))
		if rec.Code != http.StatusOK {
			t.Fatalf("save returned %d", rec.Code)
		}
	}
	post(false)
	fresh, err := config.Load(config.Options{})
	if err != nil {
		t.Fatal(err)
	}
	if fresh.FCM.ServiceAccountPath != update.ServiceAccountPath || fresh.FCM.GoogleServicesPath != update.GoogleServicesPath {
		t.Fatal("disabling FCM discarded its saved file paths")
	}
	post(true)
	fresh, err = config.Load(config.Options{})
	if err != nil {
		t.Fatal(err)
	}
	if fresh.FCM.ServiceAccountPath != "" || fresh.FCM.GoogleServicesPath != "" || fresh.FCM.ProjectID != "" || fresh.FCM.Enabled || fresh.Firebase.PublicURLSync {
		t.Fatal("explicit clear did not clear Firebase configuration")
	}
}

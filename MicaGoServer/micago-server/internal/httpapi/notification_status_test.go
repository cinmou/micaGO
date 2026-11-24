package httpapi

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"micagoserver/internal/config"
	"micagoserver/internal/notify"
	"micagoserver/internal/store"
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

func TestUnifiedPushConfigServesGeneratedVAPIDKey(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cfg, err := config.Load(config.Options{})
	if err != nil {
		t.Fatal(err)
	}
	h := &Handlers{cfg: cfg}
	dispatcher := notify.NewDispatcher(cfg)
	h.notify = dispatcher
	h.SetNotificationConfigurator(dispatcher)

	rec := httptest.NewRecorder()
	h.GetUnifiedPushConfig(rec, httptest.NewRequest(http.MethodGet, "/api/push/unifiedpush", nil))
	var response struct {
		Data struct {
			Configured     bool   `json:"configured"`
			VAPIDPublicKey string `json:"vapidPublicKey"`
		} `json:"data"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if !response.Data.Configured || len(response.Data.VAPIDPublicKey) != 87 {
		t.Fatalf("unifiedpush config = %+v", response.Data)
	}
	status := h.notificationStatus()
	if !status.UnifiedPushAvailable || status.UnifiedPushVAPIDPublicKey != response.Data.VAPIDPublicKey {
		t.Fatalf("status disagrees with endpoint: %+v", status)
	}
	info, err := os.Stat(cfg.UnifiedPush.VAPIDKeyPath)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("vapid key file: %v %v", info, err)
	}
	// Reload must reuse the persisted key, not rotate it.
	dispatcher.Reload(cfg)
	if dispatcher.UnifiedPushVAPIDPublicKey() != response.Data.VAPIDPublicKey {
		t.Fatal("reload rotated the VAPID key")
	}
}

func TestNotificationConfigUpdatePreservesRuntimeOverridesAndIsRaceFree(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cfg, err := config.Load(config.Options{
		Addr:            "127.0.0.1:4321",
		DisableSyncLoop: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	dispatcher := notify.NewDispatcher(cfg)
	h := &Handlers{
		cfg:    cfg,
		notify: dispatcher,
	}
	h.SetNotificationConfigurator(dispatcher)

	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(2)
		go func(idx int) {
			defer wg.Done()
			previews := []string{"none", "sender", "sender_and_text"}
			for j := 0; j < 10; j++ {
				preview := previews[(idx+j)%len(previews)]
				if j%2 == 0 {
					body, _ := json.Marshal(notificationsConfigRequest{
						Enabled:  true,
						Provider: "none",
						Preview:  preview,
					})
					rec := httptest.NewRecorder()
					h.PutNotificationsConfig(rec, httptest.NewRequest(http.MethodPost, "/api/server/notifications", bytes.NewReader(body)))
					if rec.Code != http.StatusOK {
						t.Errorf("PutNotificationsConfig returned %d: %s", rec.Code, rec.Body.String())
					}
				} else {
					body, _ := json.Marshal(notificationPreviewRequest{Preview: preview})
					rec := httptest.NewRecorder()
					h.PatchNotificationsPreview(rec, httptest.NewRequest(http.MethodPatch, "/api/server/notifications/preview", bytes.NewReader(body)))
					if rec.Code != http.StatusOK {
						t.Errorf("PatchNotificationsPreview returned %d: %s", rec.Code, rec.Body.String())
					}
				}
			}
		}(i)
		go func() {
			defer wg.Done()
			for j := 0; j < 15; j++ {
				recStatus := httptest.NewRecorder()
				h.GetServerStatus(recStatus, httptest.NewRequest(http.MethodGet, "/api/server/status", nil))
				if recStatus.Code != http.StatusOK {
					t.Errorf("GetServerStatus returned %d", recStatus.Code)
				}
				recURLs := httptest.NewRecorder()
				h.GetServerURLs(recURLs, httptest.NewRequest(http.MethodGet, "/api/server/urls", nil))
				if recURLs.Code != http.StatusOK {
					t.Errorf("GetServerURLs returned %d", recURLs.Code)
				}
				recFCM := httptest.NewRecorder()
				h.GetFCMClientConfig(recFCM, httptest.NewRequest(http.MethodGet, "/api/fcm/client", nil))
				if recFCM.Code != http.StatusOK {
					t.Errorf("GetFCMClientConfig returned %d", recFCM.Code)
				}
			}
		}()
	}
	wg.Wait()

	rec := httptest.NewRecorder()
	h.GetServerStatus(rec, httptest.NewRequest(http.MethodGet, "/api/server/status", nil))
	var status store.ServerStatusResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &status); err != nil {
		t.Fatal(err)
	}
	if status.Address.Listen != "127.0.0.1:4321" {
		t.Fatalf("HTTPAddr overwritten after notification update: got %q", status.Address.Listen)
	}
	if status.Sync.LoopEnabled {
		t.Fatalf("DisableSyncLoop overwritten after notification update: LoopEnabled=%v", status.Sync.LoopEnabled)
	}
}

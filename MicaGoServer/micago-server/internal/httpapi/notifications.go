package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"micagoserver/internal/config"
	"micagoserver/internal/notify"
	"micagoserver/internal/store"
)

func expandHomePath(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	if strings.HasPrefix(value, "~/") {
		if home, err := os.UserHomeDir(); err == nil && home != "" {
			return filepath.Join(home, strings.TrimPrefix(value, "~/"))
		}
	}
	return value
}

type notificationsConfigRequest struct {
	Enabled             bool   `json:"enabled"`
	Provider            string `json:"provider"`
	Preview             string `json:"preview"`
	FCMEnabled          bool   `json:"fcmEnabled"`
	FCMProjectID        string `json:"fcmProjectId"`
	ServiceAccountPath  string `json:"serviceAccountPath"`
	GoogleServicesPath  string `json:"googleServicesPath"`
	PublicURLSync       bool   `json:"publicUrlSync"`
	ClearFirebaseConfig bool   `json:"clearFirebaseConfig"`
}

// notificationsConfigResponse echoes the resulting status. It never returns the
// service-account contents or any token — only configuration flags and preview levels.
type notificationsConfigResponse struct {
	store.ServerNotificationStatus
	ServiceAccountPathSet bool `json:"serviceAccountPathSet"`
	GoogleServicesPathSet bool `json:"googleServicesPathSet"`
	FirestoreSyncEnabled  bool `json:"firestoreSyncEnabled"`
}

type testNotificationsResponse struct {
	Sent     int      `json:"sent"`
	Failed   int      `json:"failed"`
	Failures []string `json:"failures,omitempty"`
}

type notificationPreviewRequest struct {
	Preview string `json:"preview"`
}

// PutNotificationsConfig handles POST /api/server/notifications (v0.12): persist
// notification/FCM/Firebase settings and apply them to the live dispatcher.
func (h *Handlers) PutNotificationsConfig(w http.ResponseWriter, r *http.Request) {
	if h.notifyConfig == nil {
		writeInternalError(w)
		return
	}

	var req notificationsConfigRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeBadRequest(w, "invalid JSON body")
		return
	}
	req.Provider = strings.TrimSpace(req.Provider)
	req.Preview = strings.TrimSpace(req.Preview)
	req.ServiceAccountPath = strings.TrimSpace(req.ServiceAccountPath)
	req.GoogleServicesPath = strings.TrimSpace(req.GoogleServicesPath)

	if req.Preview != "none" && req.Preview != "sender" && req.Preview != "sender_and_text" {
		writeBadRequest(w, "preview must be one of: none, sender, sender_and_text")
		return
	}
	if !slices.Contains(config.NotificationProviders(), req.Provider) {
		writeBadRequest(w, "provider must be one of: "+strings.Join(config.NotificationProviders(), ", "))
		return
	}

	var (
		serviceAccountSet bool
		googleServicesSet bool
		badRequestMsg     string
	)
	func() {
		h.cfgMu.Lock()
		defer h.cfgMu.Unlock()

		// An empty editor means "keep the saved files", including when disabling
		// delivery. Removing configuration is a separate, explicit operation.
		if req.ClearFirebaseConfig {
			req.FCMEnabled = false
			req.Enabled = false
			req.Provider = "none"
			req.FCMProjectID = ""
			req.ServiceAccountPath = ""
			req.GoogleServicesPath = ""
			req.PublicURLSync = false
		} else {
			if req.ServiceAccountPath == "" {
				req.ServiceAccountPath = h.cfg.FCM.ServiceAccountPath
			}
			if req.GoogleServicesPath == "" {
				req.GoogleServicesPath = h.cfg.FCM.GoogleServicesPath
			}
		}

		expandedServiceAccountPath := expandHomePath(req.ServiceAccountPath)
		expandedGoogleServicesPath := expandHomePath(req.GoogleServicesPath)

		// Validate the service account up front so the user gets a clear error.
		if req.FCMEnabled {
			if expandedServiceAccountPath == "" {
				badRequestMsg = "serviceAccountPath is required when fcmEnabled is true"
				return
			}
			if _, err := notify.LoadServiceAccount(expandedServiceAccountPath); err != nil {
				badRequestMsg = "service account JSON could not be read or is invalid"
				return
			}
			if expandedGoogleServicesPath == "" {
				badRequestMsg = "googleServicesPath is required when fcmEnabled is true"
				return
			}
			if _, err := notify.LoadFirebaseClientConfig(expandedGoogleServicesPath); err != nil {
				badRequestMsg = "google-services.json could not be read or is invalid"
				return
			}
		}

		if err := config.UpdateNotificationsConfig(h.cfg.ConfigPath, config.NotificationsUpdate{
			Enabled:            req.Enabled,
			Provider:           req.Provider,
			Preview:            req.Preview,
			FCMEnabled:         req.FCMEnabled,
			FCMProjectID:       req.FCMProjectID,
			ServiceAccountPath: req.ServiceAccountPath,
			GoogleServicesPath: req.GoogleServicesPath,
			PublicURLSync:      req.PublicURLSync,
		}); err != nil {
			badRequestMsg = err.Error()
			return
		}

		// Update only notification/FCM/Firebase fields in memory so runtime CLI
		// overrides (HTTPAddr, DisableSyncLoop, ConfigPath, etc.) are preserved.
		h.cfg.NotificationsEnabled = req.Enabled
		h.cfg.NotificationProvider = req.Provider
		h.cfg.NotificationPreview = req.Preview
		h.cfg.FCM.Enabled = req.FCMEnabled
		h.cfg.FCM.ProjectID = strings.TrimSpace(req.FCMProjectID)
		h.cfg.FCM.ServiceAccountPath = expandedServiceAccountPath
		h.cfg.FCM.GoogleServicesPath = expandedGoogleServicesPath
		h.cfg.Firebase.PublicURLSync = req.PublicURLSync

		updated := h.cfg
		serviceAccountSet = expandedServiceAccountPath != ""
		googleServicesSet = expandedGoogleServicesPath != ""
		h.notifyConfig.Reload(updated)
	}()
	if badRequestMsg != "" {
		writeBadRequest(w, badRequestMsg)
		return
	}

	writeJSON(w, http.StatusOK, notificationsConfigResponse{
		ServerNotificationStatus: h.notificationStatus(),
		ServiceAccountPathSet:    serviceAccountSet,
		GoogleServicesPathSet:    googleServicesSet,
		FirestoreSyncEnabled:     h.notifyConfig.FirestoreSyncEnabled(),
	})
}

// PatchNotificationsPreview updates only the notification privacy preview mode.
// The Android client uses this for "show message text" without touching the
// user's FCM project, service-account path, or Firestore settings.
func (h *Handlers) PatchNotificationsPreview(w http.ResponseWriter, r *http.Request) {
	if h.notifyConfig == nil {
		writeInternalError(w)
		return
	}
	var req notificationPreviewRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeBadRequest(w, "invalid JSON body")
		return
	}
	req.Preview = strings.TrimSpace(req.Preview)
	if req.Preview != "none" && req.Preview != "sender" && req.Preview != "sender_and_text" {
		writeBadRequest(w, "preview must be one of: none, sender, sender_and_text")
		return
	}

	var (
		serviceAccountSet bool
		googleServicesSet bool
		badRequestMsg     string
	)
	func() {
		h.cfgMu.Lock()
		defer h.cfgMu.Unlock()

		if err := config.UpdateNotificationsConfig(h.cfg.ConfigPath, config.NotificationsUpdate{
			Enabled:            h.cfg.NotificationsEnabled,
			Provider:           h.cfg.NotificationProvider,
			Preview:            req.Preview,
			FCMEnabled:         h.cfg.FCM.Enabled,
			FCMProjectID:       h.cfg.FCM.ProjectID,
			ServiceAccountPath: h.cfg.FCM.ServiceAccountPath,
			GoogleServicesPath: h.cfg.FCM.GoogleServicesPath,
			PublicURLSync:      h.cfg.Firebase.PublicURLSync,
		}); err != nil {
			badRequestMsg = err.Error()
			return
		}

		h.cfg.NotificationPreview = req.Preview
		updated := h.cfg
		serviceAccountSet = strings.TrimSpace(h.cfg.FCM.ServiceAccountPath) != ""
		googleServicesSet = strings.TrimSpace(h.cfg.FCM.GoogleServicesPath) != ""
		h.notifyConfig.Reload(updated)
	}()
	if badRequestMsg != "" {
		writeBadRequest(w, badRequestMsg)
		return
	}

	writeJSON(w, http.StatusOK, notificationsConfigResponse{
		ServerNotificationStatus: h.notificationStatus(),
		ServiceAccountPathSet:    serviceAccountSet,
		GoogleServicesPathSet:    googleServicesSet,
		FirestoreSyncEnabled:     h.notifyConfig.FirestoreSyncEnabled(),
	})
}

// TestNotifications handles POST /api/server/notifications/test.
// One settings-page action tests every FCM / UnifiedPush device; per-device
// testing was removed so device cards stay focused on paired-device privacy.
func (h *Handlers) TestNotifications(w http.ResponseWriter, r *http.Request) {
	if h.devices == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "push_device_registry_unavailable", "device registry is not available")
		return
	}
	if h.notify == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "push_dispatcher_unavailable", "notification dispatcher is not available")
		return
	}

	devices, err := h.devices.ListDevices(r.Context())
	if err != nil {
		h.logInternal("list devices for notification test", err)
		writeAPIError(w, http.StatusInternalServerError, "push_device_list_failed", "could not list registered devices: "+err.Error())
		return
	}
	if len(devices) == 0 {
		writeAPIError(w, http.StatusBadRequest, "push_no_devices", "No registered devices. Open micaGO on Android and let it connect once.")
		return
	}

	pushDevices := make([]store.DeviceRecord, 0, len(devices))
	for _, device := range devices {
		if (device.PushProvider == "fcm" || device.PushProvider == "unifiedpush") && device.PushEnabled && device.PushToken != nil && strings.TrimSpace(*device.PushToken) != "" {
			pushDevices = append(pushDevices, device)
		}
	}
	if len(pushDevices) == 0 {
		writeAPIError(w, http.StatusBadRequest, "push_no_fcm_devices", "No devices registered for push. Open micaGO on Android and let it reconnect.")
		return
	}

	resp := testNotificationsResponse{}
	for _, device := range pushDevices {
		err := h.notify.SendTest(r.Context(), device)
		switch {
		case err == nil:
			resp.Sent++
		case errors.Is(err, notify.ErrPushNotConfigured):
			resp.Failed++
			resp.Failures = append(resp.Failures, device.Name+": push is not configured")
		default:
			resp.Failed++
			resp.Failures = append(resp.Failures, device.Name+": "+err.Error())
		}
	}

	status := http.StatusOK
	if resp.Sent == 0 {
		status = http.StatusBadRequest
	}
	writeJSON(w, status, map[string]testNotificationsResponse{"data": resp})
}

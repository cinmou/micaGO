package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"micagoserver/internal/config"
	"micagoserver/internal/notify"
	"micagoserver/internal/store"
)

type notificationsConfigRequest struct {
	Enabled            bool   `json:"enabled"`
	Provider           string `json:"provider"`
	Preview            string `json:"preview"`
	FCMEnabled         bool   `json:"fcmEnabled"`
	FCMProjectID       string `json:"fcmProjectId"`
	ServiceAccountPath string `json:"serviceAccountPath"`
	GoogleServicesPath string `json:"googleServicesPath"`
	PublicURLSync      bool   `json:"publicUrlSync"`
}

// notificationsConfigResponse echoes the resulting status. It never returns the
// service-account contents or any token — only flags/paths/levels.
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
	switch req.Provider {
	case "none", "webhook", "fcm", "hms", "harmony_push", "ntfy":
	default:
		writeBadRequest(w, "provider must be one of: none, webhook, fcm, hms, harmony_push, ntfy")
		return
	}

	// Validate the service account up front so the user gets a clear error.
	if req.FCMEnabled {
		if req.ServiceAccountPath == "" {
			req.ServiceAccountPath = h.cfg.FCM.ServiceAccountPath
		}
		if req.GoogleServicesPath == "" {
			req.GoogleServicesPath = h.cfg.FCM.GoogleServicesPath
		}
		if req.ServiceAccountPath == "" {
			writeBadRequest(w, "serviceAccountPath is required when fcmEnabled is true")
			return
		}
		if _, err := notify.LoadServiceAccount(req.ServiceAccountPath); err != nil {
			writeBadRequest(w, "invalid service account: "+err.Error())
			return
		}
		if req.GoogleServicesPath == "" {
			writeBadRequest(w, "googleServicesPath is required when fcmEnabled is true")
			return
		}
		if _, err := notify.LoadFirebaseClientConfig(req.GoogleServicesPath); err != nil {
			writeBadRequest(w, "invalid google-services.json: "+err.Error())
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
		writeBadRequest(w, err.Error())
		return
	}

	// Reload from the freshly-written config so the dispatcher (and status)
	// reflect the change without a restart.
	fresh, err := config.Load(config.Options{})
	if err != nil {
		h.logInternal("reload config after notifications update", err)
		writeInternalError(w)
		return
	}
	h.cfg = fresh
	h.notifyConfig.Reload(fresh)

	writeJSON(w, http.StatusOK, notificationsConfigResponse{
		ServerNotificationStatus: h.notificationStatus(),
		ServiceAccountPathSet:    req.ServiceAccountPath != "",
		GoogleServicesPathSet:    req.GoogleServicesPath != "",
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
		writeBadRequest(w, err.Error())
		return
	}

	fresh, err := config.Load(config.Options{})
	if err != nil {
		h.logInternal("reload config after notification preview update", err)
		writeInternalError(w)
		return
	}
	h.cfg = fresh
	h.notifyConfig.Reload(fresh)

	writeJSON(w, http.StatusOK, notificationsConfigResponse{
		ServerNotificationStatus: h.notificationStatus(),
		ServiceAccountPathSet:    strings.TrimSpace(h.cfg.FCM.ServiceAccountPath) != "",
		GoogleServicesPathSet:    strings.TrimSpace(h.cfg.FCM.GoogleServicesPath) != "",
		FirestoreSyncEnabled:     h.notifyConfig.FirestoreSyncEnabled(),
	})
}

// TestNotifications handles POST /api/server/notifications/test.
// One settings-page action tests the current FCM delivery path; per-device
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

	fcmDevices := make([]store.DeviceRecord, 0, len(devices))
	for _, device := range devices {
		if device.PushProvider == "fcm" && device.PushEnabled && device.PushToken != nil && strings.TrimSpace(*device.PushToken) != "" {
			fcmDevices = append(fcmDevices, device)
		}
	}
	if len(fcmDevices) == 0 {
		writeAPIError(w, http.StatusBadRequest, "push_no_fcm_devices", "No registered FCM devices. Open micaGO on Android and let it reconnect.")
		return
	}

	resp := testNotificationsResponse{}
	for _, device := range fcmDevices {
		err := h.notify.SendTest(r.Context(), device)
		switch {
		case err == nil:
			resp.Sent++
		case errors.Is(err, notify.ErrPushNotConfigured):
			resp.Failed++
			resp.Failures = append(resp.Failures, device.Name+": push is not configured")
		case errors.Is(err, notify.ErrNotImplemented):
			resp.Failed++
			resp.Failures = append(resp.Failures, device.Name+": notification provider is not implemented")
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

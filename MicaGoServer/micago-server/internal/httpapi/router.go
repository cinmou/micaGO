package httpapi

import (
	"net/http"

	"micagoserver/internal/realtime"
)

func NewRouter(h *Handlers, hub *realtime.Hub, auth AuthConfig) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/health", h.GetHealth)
	mux.Handle("GET /api/server/info", auth.Wrap(http.HandlerFunc(h.GetServerInfo)))
	mux.Handle("GET /api/server/status", auth.Wrap(http.HandlerFunc(h.GetServerStatus)))
	mux.Handle("GET /api/server/connections", auth.Wrap(http.HandlerFunc(h.GetServerConnections)))
	mux.Handle("GET /api/server/urls", auth.Wrap(http.HandlerFunc(h.GetServerURLs)))
	mux.Handle("POST /api/server/public-url", auth.Wrap(http.HandlerFunc(h.SetPublicURL)))
	mux.Handle("POST /api/server/public-url/check", auth.Wrap(http.HandlerFunc(h.CheckPublicURL)))
	mux.Handle("POST /api/auth/check", auth.Wrap(http.HandlerFunc(h.CheckAuth)))
	mux.Handle("GET /api/messages/recent", auth.Wrap(http.HandlerFunc(h.GetRecentMessages)))
	mux.Handle("GET /api/messages/history", auth.Wrap(http.HandlerFunc(h.GetMergedMessageHistory)))
	mux.Handle("GET /api/messages/delta", auth.Wrap(http.HandlerFunc(h.GetMessagesDelta)))
	mux.Handle("GET /api/messages/actions/capabilities", auth.Wrap(http.HandlerFunc(h.GetMessageActionCapabilities)))
	mux.Handle("POST /api/messages/actions/refresh", auth.Wrap(http.HandlerFunc(h.RefreshMessageActionCapabilities)))
	mux.Handle("GET /api/debug/recent-messages", auth.Wrap(http.HandlerFunc(h.GetDebugRecentMessages)))
	mux.Handle("GET /api/sync/settings", auth.Wrap(http.HandlerFunc(h.GetSyncSettings)))
	mux.Handle("PUT /api/sync/settings", auth.Wrap(http.HandlerFunc(h.PutSyncSettings)))
	mux.Handle("POST /api/sync/now", auth.Wrap(http.HandlerFunc(h.SyncNow)))
	mux.Handle("GET /api/test-contact", auth.Wrap(http.HandlerFunc(h.GetTestContact)))
	mux.Handle("PUT /api/test-contact", auth.Wrap(http.HandlerFunc(h.PutTestContact)))
	mux.Handle("POST /api/test-contact/inbound", auth.Wrap(http.HandlerFunc(h.PostTestContactInbound)))
	mux.Handle("GET /api/chats", auth.Wrap(http.HandlerFunc(h.GetChats)))
	mux.Handle("GET /api/chats/{guid}/messages", auth.Wrap(http.HandlerFunc(h.GetChatMessages)))
	mux.Handle("POST /api/chats/{guid}/send", auth.Wrap(http.HandlerFunc(h.SendText)))
	mux.Handle("POST /api/chats/{guid}/send-attachment", auth.Wrap(http.HandlerFunc(h.SendAttachment)))
	mux.Handle("POST /api/chats/{guid}/send-attachments", auth.Wrap(http.HandlerFunc(h.SendAttachments)))
	mux.Handle("POST /api/chats/{guid}/messages/{messageGuid}/edit", auth.Wrap(http.HandlerFunc(h.EditMessage)))
	mux.Handle("POST /api/chats/{guid}/messages/{messageGuid}/retract", auth.Wrap(http.HandlerFunc(h.RetractMessage)))
	mux.Handle("DELETE /api/chats/{guid}/messages/{messageGuid}", auth.Wrap(http.HandlerFunc(h.DeleteMessage)))
	mux.Handle("GET /api/attachments/{guid}", auth.Wrap(http.HandlerFunc(h.GetAttachment)))
	mux.Handle("GET /api/attachments/{guid}/playable", auth.Wrap(http.HandlerFunc(h.GetAttachmentPlayable)))
	mux.Handle("GET /api/attachments/{guid}/preview", auth.Wrap(http.HandlerFunc(h.GetAttachmentPreview)))
	mux.Handle("POST /api/devices/register", auth.Wrap(http.HandlerFunc(h.RegisterDevice)))
	mux.Handle("GET /api/devices", auth.Wrap(http.HandlerFunc(h.ListDevices)))
	mux.Handle("PATCH /api/devices/{id}", auth.Wrap(http.HandlerFunc(h.PatchDevice)))
	mux.Handle("POST /api/devices/{id}/heartbeat", auth.Wrap(http.HandlerFunc(h.DeviceHeartbeat)))
	mux.Handle("DELETE /api/devices/{id}", auth.Wrap(http.HandlerFunc(h.DeleteDevice)))
	mux.Handle("GET /api/fcm/client", auth.Wrap(http.HandlerFunc(h.GetFCMClientConfig)))
	mux.Handle("POST /api/server/notifications/test", auth.Wrap(http.HandlerFunc(h.TestNotifications)))
	mux.Handle("PATCH /api/server/notifications/preview", auth.Wrap(http.HandlerFunc(h.PatchNotificationsPreview)))
	mux.Handle("PUT /api/server/contacts/cache", auth.Wrap(http.HandlerFunc(h.PutContactCache)))
	mux.Handle("GET /api/sync/rules", auth.Wrap(http.HandlerFunc(h.GetSyncRules)))
	mux.Handle("PUT /api/sync/rules", auth.Wrap(http.HandlerFunc(h.PutSyncRule)))
	mux.Handle("DELETE /api/sync/rules/{kind}/{value}", auth.Wrap(http.HandlerFunc(h.DeleteSyncRule)))
	mux.Handle("PUT /api/sync/policy", auth.Wrap(http.HandlerFunc(h.PutSyncPolicy)))
	mux.Handle("POST /api/server/notifications", auth.Wrap(http.HandlerFunc(h.PutNotificationsConfig)))
	if hub != nil {
		mux.Handle("GET /ws", websocketAuthHandler(hub, auth))
	}
	return mux
}

func websocketAuthHandler(hub *realtime.Hub, auth AuthConfig) http.Handler {
	if hub == nil {
		return http.NotFoundHandler()
	}
	if !auth.Enabled {
		return hub
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !auth.ValidateWebSocketRequest(r) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		hub.ServeHTTP(w, r)
	})
}

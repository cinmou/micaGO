package notify

import (
	"context"
	"errors"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"micagoserver/internal/config"
	"micagoserver/internal/relaydb"
	"micagoserver/internal/store"
)

type Dispatcher struct {
	mu              sync.RWMutex
	enabled         bool
	previewMode     string
	defaultProvider string
	providers       map[string]Provider
	fcmActive       bool
	firestore       *FirestoreURLSync
	pruneFunc       func(deviceID string)
	contacts        *contactCache
}

func NewDispatcher(cfg config.Config) *Dispatcher {
	d := &Dispatcher{contacts: newContactCache()}
	d.apply(cfg)
	return d
}

// Reload rebuilds providers/state from a fresh config (used by the
// notifications-config write endpoint so changes take effect without restart).
func (d *Dispatcher) Reload(cfg config.Config) {
	d.apply(cfg)
}

// SetPruneFunc wires the dead-token pruning callback (clears a device's push
// token). Called once after the device store is available.
func (d *Dispatcher) SetPruneFunc(fn func(deviceID string)) {
	d.mu.Lock()
	d.pruneFunc = fn
	d.mu.Unlock()
}

// SetContactCache replaces the local-only contact display-name cache used for
// push notification titles. The cache is in-memory and contains no message data.
func (d *Dispatcher) SetContactCache(entries []ContactEntry) {
	if d.contacts == nil {
		d.contacts = newContactCache()
	}
	d.contacts.Set(entries)
}

func (d *Dispatcher) apply(cfg config.Config) {
	providers := map[string]Provider{
		"none":         NoneProvider{},
		"webhook":      WebhookProvider{URL: cfg.WebhookURL},
		"hms":          NewHMSStubProvider("hms"),
		"harmony_push": NewHMSStubProvider("harmony_push"),
		"ntfy":         NtfyStubProvider{},
	}

	fcmActive := false
	var firestore *FirestoreURLSync
	if cfg.FCM.Enabled && strings.TrimSpace(cfg.FCM.ServiceAccountPath) != "" {
		sa, err := LoadServiceAccount(cfg.FCM.ServiceAccountPath)
		if err != nil {
			log.Printf("fcm: service account not loaded (%v); fcm push disabled", err)
			providers["fcm"] = FCMStubProvider{}
		} else {
			projectID := cfg.FCM.ProjectID
			if projectID == "" {
				projectID = sa.ProjectID
			}
			httpClient := &http.Client{Timeout: 15 * time.Second}
			tokens := NewTokenSource(sa, httpClient, scopeFCM, scopeFirestore)
			providers["fcm"] = NewFCMProvider(projectID, tokens, httpClient, 24*time.Hour, func(id string) {
				d.invokePrune(id)
			})
			fcmActive = true
			if cfg.Firebase.PublicURLSync {
				firestore = NewFirestoreURLSync(projectID, cfg.Firebase.URLCollection, cfg.Firebase.URLDocument, tokens, httpClient)
			}
		}
	} else {
		providers["fcm"] = FCMStubProvider{}
	}

	d.mu.Lock()
	d.enabled = cfg.NotificationsEnabled
	d.previewMode = cfg.NotificationPreview
	d.defaultProvider = cfg.NotificationProvider
	d.providers = providers
	d.fcmActive = fcmActive
	d.firestore = firestore
	d.mu.Unlock()
}

// Enabled reports whether notifications are enabled (live; reflects Reload).
func (d *Dispatcher) Enabled() bool {
	d.mu.RLock()
	defer d.mu.RUnlock()
	return d.enabled
}

// PreviewMode returns the current preview level (none|sender|sender_and_text).
func (d *Dispatcher) PreviewMode() string {
	d.mu.RLock()
	defer d.mu.RUnlock()
	return d.previewMode
}

// DefaultProvider returns the configured default notification provider.
func (d *Dispatcher) DefaultProvider() string {
	d.mu.RLock()
	defer d.mu.RUnlock()
	return d.defaultProvider
}

func (d *Dispatcher) invokePrune(id string) {
	d.mu.RLock()
	fn := d.pruneFunc
	d.mu.RUnlock()
	if fn != nil {
		fn(id)
	}
}

// ProviderNames is the set of provider names accepted at device registration.
func (d *Dispatcher) ProviderNames() []string {
	return []string{"none", "webhook", "fcm", "hms", "harmony_push", "ntfy"}
}

// ImplementedProviders lists providers that actually deliver right now. `fcm` is
// included only when a valid service account is configured.
func (d *Dispatcher) ImplementedProviders() []string {
	d.mu.RLock()
	defer d.mu.RUnlock()
	out := []string{"none", "webhook"}
	if d.fcmActive {
		out = append(out, "fcm")
	}
	return out
}

// FirestoreSyncEnabled reports whether optional public-URL sync is active.
func (d *Dispatcher) FirestoreSyncEnabled() bool {
	d.mu.RLock()
	defer d.mu.RUnlock()
	return d.firestore != nil
}

// SyncPublicURL writes the public URL to Firestore when the optional sync is
// enabled+configured; a no-op otherwise.
func (d *Dispatcher) SyncPublicURL(ctx context.Context, publicURL string) {
	d.mu.RLock()
	fs := d.firestore
	d.mu.RUnlock()
	if fs == nil || strings.TrimSpace(publicURL) == "" {
		return
	}
	if err := fs.SetPublicURL(ctx, publicURL); err != nil {
		log.Printf("firestore public-url sync: %v", err)
	}
}

func (d *Dispatcher) DispatchNewMessages(ctx context.Context, devices []store.DeviceRecord, events []relaydb.NotificationEvent) error {
	d.mu.RLock()
	enabled := d.enabled
	previewMode := d.previewMode
	providers := d.providers
	d.mu.RUnlock()
	if !enabled {
		return nil
	}

	pushReady := 0
	for _, device := range devices {
		if device.PushEnabled && device.PushProvider != "none" {
			if _, ok := providers[device.PushProvider]; ok {
				pushReady++
			}
		}
	}
	sent := 0
	skippedOutgoing := 0
	skippedNoDevice := 0
	errorsLogged := 0
	for _, event := range events {
		if event.Message.IsFromMe {
			skippedOutgoing++
			continue
		}
		notification := d.buildNotification(event, previewMode)
		for _, device := range devices {
			if !device.PushEnabled || device.PushProvider == "none" {
				skippedNoDevice++
				continue
			}
			provider, ok := providers[device.PushProvider]
			if !ok {
				skippedNoDevice++
				continue
			}
			if err := provider.Send(ctx, device, notification); err != nil && !errors.Is(err, ErrPushNotConfigured) {
				errorsLogged++
				log.Printf("push dispatch (%s): %v", device.PushProvider, err)
				continue
			}
			sent++
		}
	}
	log.Printf("push dispatch summary: events=%d devices=%d push_ready=%d sent=%d skipped_outgoing=%d skipped_no_device=%d errors=%d",
		len(events), len(devices), pushReady, sent, skippedOutgoing, skippedNoDevice, errorsLogged)
	return nil
}

func (d *Dispatcher) buildNotification(event relaydb.NotificationEvent, previewMode string) Notification {
	notification := buildNotification(event, previewMode)
	handle := strings.TrimSpace(notification.Handle)
	if handle == "" || d.contacts == nil {
		return notification
	}
	if name := d.contacts.Resolve(handle); name != "" {
		notification.SenderName = name
		if event.IsGroup {
			if notification.Title == handle {
				notification.Title = notification.ConversationTitle
			}
		} else {
			notification.Title = name
			notification.ConversationTitle = name
		}
	}
	return notification
}

func (d *Dispatcher) SendTest(ctx context.Context, device store.DeviceRecord) error {
	d.mu.RLock()
	enabled := d.enabled
	previewMode := d.previewMode
	provider, ok := d.providers[device.PushProvider]
	d.mu.RUnlock()

	if !enabled {
		return ErrPushNotConfigured
	}
	if !device.PushEnabled || device.PushProvider == "none" {
		return ErrPushNotConfigured
	}
	if !ok {
		return ErrNotImplemented
	}
	return provider.Send(ctx, device, Notification{
		Type:        "test",
		Title:       "micaGO Server test notification",
		Body:        "Notifications are configured for this device",
		PreviewMode: previewMode,
		CreatedAt:   time.Now().UnixMilli(),
	})
}

func buildNotification(event relaydb.NotificationEvent, previewMode string) Notification {
	// C31/C32: "conversation = where, sender = who, body = what". Android
	// MessagingStyle group conversations need the group name as conversation title
	// and the sender as Person; one-to-one chats keep the contact as both.
	conversationTitle := event.ChatLabel()
	handle := ""
	if event.Message.Handle != nil {
		handle = event.Message.Handle.ID
	}
	sender := handle
	if !event.IsGroup && conversationTitle != "" {
		sender = conversationTitle
	}
	if sender == "" {
		sender = conversationTitle
	}

	title := "New message"
	body := ""
	switch previewMode {
	case "none":
		// Privacy: no sender, no text — just a generic wake.
	case "sender_and_text":
		if event.IsGroup && conversationTitle != "" {
			title = conversationTitle
		} else if sender != "" {
			title = sender
		}
		body = messagePreviewText(event.Message)
	default: // "sender" (and any unknown value): show who, not what.
		if event.IsGroup && conversationTitle != "" {
			title = conversationTitle
		} else if sender != "" {
			title = sender
		}
	}
	if conversationTitle == "" {
		conversationTitle = title
	}
	if sender == "" {
		sender = title
	}

	var sourceRowID int64
	if event.Message.SourceRowID != nil {
		sourceRowID = *event.Message.SourceRowID
	}

	return Notification{
		Type:              "message:new",
		MessageGUID:       event.Message.GUID,
		ChatGUID:          event.ChatGUID,
		SourceRowID:       sourceRowID,
		Title:             title,
		Body:              body,
		SenderName:        sender,
		ConversationTitle: conversationTitle,
		IsGroup:           event.IsGroup,
		Handle:            handle,
		PreviewMode:       previewMode,
		CreatedAt:         time.Now().UnixMilli(),
	}
}

func messagePreviewText(message store.MessageJSON) string {
	if text := strings.TrimSpace(stringValue(message.Text)); text != "" {
		return text
	}
	if len(message.Attachments) == 0 {
		return ""
	}
	a := message.Attachments[0]
	mime := strings.TrimSpace(stringValue(a.MimeType))
	switch {
	case a.IsSticker || a.DisplayKind == "sticker" || a.AttachmentKind == "sticker":
		return "（贴纸）"
	case a.IsVoiceMessage:
		return "（语音）"
	case a.AttachmentKind == "image" || strings.HasPrefix(mime, "image/"):
		return "（图片）"
	case a.AttachmentKind == "video" || strings.HasPrefix(mime, "video/"):
		return "（视频）"
	case a.AttachmentKind == "audio" || strings.HasPrefix(mime, "audio/"):
		return "（音频）"
	default:
		return "（文件）"
	}
}

func stringValue(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}

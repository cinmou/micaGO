package store

type HealthResponse struct {
	OK bool `json:"ok"`
}

type HandleJSON struct {
	ID      string  `json:"id"`
	Service *string `json:"service"`
}

type AttachmentJSON struct {
	GUID             string  `json:"guid"`
	Filename         *string `json:"filename"`
	MimeType         *string `json:"mimeType"`
	OriginalMimeType *string `json:"originalMimeType,omitempty"`
	TransferName     *string `json:"transferName"`
	TotalBytes       int64   `json:"totalBytes"`
	DownloadURL      string  `json:"downloadUrl"`
	PreviewURL       string  `json:"previewUrl,omitempty"`
	// v0.11.5 message-fidelity additive fields. All are derived read-only;
	// clients that predate them simply ignore the extra keys.
	Uti                    *string `json:"uti"`
	IsSticker              bool    `json:"isSticker"`
	AttachmentKind         string  `json:"attachmentKind"`
	IsVoiceMessage         bool    `json:"isVoiceMessage"`
	DisplayKind            string  `json:"displayKind"`
	IsPreviewableImage     bool    `json:"isPreviewableImage"`
	NeedsPreviewConversion bool    `json:"needsPreviewConversion"`
}

type ChatJSON struct {
	GUID            string  `json:"guid"`
	ChatIdentifier  *string `json:"chatIdentifier"`
	ServiceName     *string `json:"serviceName"`
	ServiceCategory string  `json:"serviceCategory,omitempty"`
	// EffectiveService (C21) is the single server-authoritative service that the
	// client uses for the badge AND sendability — message-aware, prefers
	// iMessage. The same value gates sending server-side. imessage|sms|rcs|unknown.
	EffectiveService string `json:"effectiveService,omitempty"`
	// CanSendText / CanSendAttachments (C21c) are explicit server-computed
	// capabilities — the client consumes these booleans directly and never
	// re-derives sendability from the service + setting. They match exactly what
	// the send handlers enforce.
	CanSendText        bool     `json:"canSendText"`
	CanSendAttachments bool     `json:"canSendAttachments"`
	DisplayName        *string  `json:"displayName"`
	IsArchived         bool     `json:"isArchived"`
	Participants       []string `json:"participants,omitempty"`
	IsGroup            bool     `json:"isGroup"`

	// C7 renderable-timeline summary (additive). Populated by the relay store so
	// the client can hide noisy chats and show a real last-message preview.
	HasRenderableMessages   bool    `json:"hasRenderableMessages"`
	LatestRenderableAt      *int64  `json:"latestRenderableAt,omitempty"`
	LatestRenderablePreview *string `json:"latestRenderablePreview,omitempty"`
	// LatestRenderableFromMe reports whether the latest renderable message is
	// outgoing — the client uses it so a chat whose newest message was sent by me
	// (from the Mac or another device) never lights an unread dot.
	LatestRenderableFromMe bool   `json:"latestRenderableFromMe"`
	UnsupportedOnly        bool   `json:"unsupportedOnly"`
	HiddenReason           string `json:"hiddenReason,omitempty"` // "" | "debug_only" | "empty"
}

type MessageJSON struct {
	GUID                 string           `json:"guid"`
	SourceRowID          *int64           `json:"sourceRowId,omitempty"` // chat.db ROWID — the delta cursor (C21)
	Text                 *string          `json:"text"`
	Subject              *string          `json:"subject"`
	Service              *string          `json:"service"`
	Account              *string          `json:"account,omitempty"`
	ServiceCategory      string           `json:"serviceCategory,omitempty"`
	DateCreated          *int64           `json:"dateCreated"`
	DateRead             *int64           `json:"dateRead"`
	DateDelivered        *int64           `json:"dateDelivered"`
	IsFromMe             bool             `json:"isFromMe"`
	IsRead               bool             `json:"isRead"`
	IsDelivered          bool             `json:"isDelivered"`
	Handle               *HandleJSON      `json:"handle"`
	CacheHasAttachments  bool             `json:"cacheHasAttachments"`
	Attachments          []AttachmentJSON `json:"attachments"`
	HasAttributedBody    bool             `json:"hasAttributedBody,omitempty"`
	SemanticKind         string           `json:"semanticKind,omitempty"`
	RenderRecommendation string           `json:"renderRecommendation,omitempty"`
	IsDebugOnly          bool             `json:"isDebugOnly,omitempty"`
	UnsupportedReason    string           `json:"unsupportedReason,omitempty"`

	// BlueBubbles-compatible semantic fields (v0.13). All additive and optional:
	// pointers omit when absent so pre-existing clients see an unchanged payload.
	// See docs/bluebubbles-compatibility-notes.md.
	ChatGUID              *string `json:"chatGuid,omitempty"`
	AssociatedMessageType *int64  `json:"associatedMessageType,omitempty"` // reaction code (2000-2005 add / 3000-3005 remove)
	AssociatedMessageGUID *string `json:"associatedMessageGuid,omitempty"` // tapback target (p:/bp: prefixed)
	ThreadOriginatorGUID  *string `json:"threadOriginatorGuid,omitempty"`  // reply target
	ItemType              *int64  `json:"itemType,omitempty"`
	GroupActionType       *int64  `json:"groupActionType,omitempty"`
	GroupTitle            *string `json:"groupTitle,omitempty"`
	BalloonBundleID       *string `json:"balloonBundleId,omitempty"`
	ExpressiveSendStyleID *string `json:"expressiveSendStyleId,omitempty"`
	Error                 *int64  `json:"error,omitempty"`
	DateRetracted         *int64  `json:"dateRetracted,omitempty"`
	DateEdited            *int64  `json:"dateEdited,omitempty"`
	// Always-present additive booleans (old clients ignore unknown keys).
	PayloadDataPresent bool `json:"payloadDataPresent"`
	IsRetracted        bool `json:"isRetracted"`
	IsEdited           bool `json:"isEdited"`
}

type ListMeta struct {
	Limit  int `json:"limit"`
	Offset int `json:"offset"`
}

type ChatListResponse struct {
	Data []ChatJSON `json:"data"`
	Meta ListMeta   `json:"meta"`
}

type MessageListResponse struct {
	Data []MessageJSON `json:"data"`
	Meta ListMeta      `json:"meta"`
}

type MessageHistoryResponse struct {
	Data       []MessageJSON `json:"data"`
	NextCursor string        `json:"nextCursor,omitempty"`
	HasMore    bool          `json:"hasMore"`
}

type MessageRow struct {
	ChatGUID            *string
	SourceRowID         *int64
	GUID                string
	Text                *string
	AttributedBody      []byte
	Subject             *string
	Service             *string
	Account             *string
	DateRaw             int64
	DateReadRaw         *int64
	DateDeliveredRaw    *int64
	IsFromMe            bool
	IsRead              bool
	IsDelivered         bool
	HandleValue         *string
	HandleService       *string
	CacheHasAttachments bool
}

type SyncChatRow struct {
	GUID             string
	ChatIdentifier   *string
	ServiceName      *string
	DisplayName      *string
	IsArchived       bool
	Style            *int64
	ParticipantCount int64
	Participants     []string
}

type SyncMessageRow struct {
	ChatGUID            string
	SourceRowID         int64
	GUID                string
	Text                *string
	Subject             *string
	Service             *string
	Account             *string
	DateCreated         *int64
	DateRead            *int64
	DateDelivered       *int64
	IsFromMe            bool
	IsRead              bool
	IsDelivered         bool
	HandleID            *string
	HandleService       *string
	CacheHasAttachments bool
	HasAttributedBody   bool

	// BlueBubbles-compatible semantic fields carried chat.db → relay (v0.13).
	// Populated only when the corresponding chat.db column exists.
	AssociatedMessageType *int64
	AssociatedMessageGUID *string
	ThreadOriginatorGUID  *string
	ItemType              *int64
	GroupActionType       *int64
	GroupTitle            *string
	BalloonBundleID       *string
	ExpressiveSendStyleID *string
	PayloadDataPresent    bool
}

// MessageUpdateRow is a chat.db row fetched by the v0.11.x lookback update pass.
// Mutable-state fields are populated only when the corresponding capability is
// available; otherwise they remain nil/zero and are ignored. Dates are Unix ms.
type MessageUpdateRow struct {
	GUID                string
	ChatGUID            string
	Text                *string
	Subject             *string
	Service             *string
	DateCreated         *int64
	DateRead            *int64
	DateDelivered       *int64
	DateEdited          *int64
	DateRetracted       *int64
	ErrorCode           int64
	IsFromMe            bool
	IsRead              bool
	IsDelivered         bool
	HandleID            *string
	HandleService       *string
	CacheHasAttachments bool
}

// State extracts the mutable MessageState used for fingerprinting/diffing.
func (r MessageUpdateRow) State() MessageState {
	return MessageState{
		IsRead:        r.IsRead,
		DateRead:      r.DateRead,
		IsDelivered:   r.IsDelivered,
		DateDelivered: r.DateDelivered,
		DateEdited:    r.DateEdited,
		DateRetracted: r.DateRetracted,
		ErrorCode:     r.ErrorCode,
	}
}

type SyncAttachmentRow struct {
	GUID           string
	MessageGUID    string
	Filename       *string
	MimeType       *string
	TransferName   *string
	TotalBytes     int64
	LocalPath      *string
	IsOutgoing     bool
	HideAttachment bool
	CreatedAt      *int64
	Uti            *string
	IsSticker      bool
}

type AttachmentMeta struct {
	GUID           string
	MessageGUID    string
	Filename       *string
	MimeType       *string
	TransferName   *string
	TotalBytes     int64
	LocalPath      *string
	IsOutgoing     bool
	HideAttachment bool
	CreatedAt      *int64
	Uti            *string
	IsSticker      bool
}

type ChatInfo struct {
	GUID        string
	ServiceName *string
	// EffectiveService (C21) is the resolved, message-aware service category the
	// send gate uses, identical to the value exposed on ChatJSON.
	EffectiveService string
}

type DeviceRecord struct {
	ID           string
	Name         string
	Platform     string
	ClientType   string
	AppVersion   string
	Mode         string
	PushProvider string
	PushToken    *string
	PushEnabled  bool
	Background   bool
	LastSeenAt   *int64
	CreatedAt    int64
	UpdatedAt    int64
}

type DeviceJSON struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	Platform     string `json:"platform"`
	ClientType   string `json:"clientType"`
	AppVersion   string `json:"appVersion"`
	Mode         string `json:"mode"`
	PushProvider string `json:"pushProvider"`
	PushEnabled  bool   `json:"pushEnabled"`
	PushTokenSet bool   `json:"pushTokenSet"`
	Background   bool   `json:"background"`
	Connected    bool   `json:"connected"`
	LastSeenAt   *int64 `json:"lastSeenAt"`
	CreatedAt    int64  `json:"createdAt"`
	UpdatedAt    int64  `json:"updatedAt"`
}

type DeviceResponse struct {
	Data DeviceJSON `json:"data"`
}

type DeviceListResponse struct {
	Data []DeviceJSON `json:"data"`
}

type ServerInfoResponse struct {
	Name                  string         `json:"name"`
	Version               string         `json:"version"`
	BaseURL               string         `json:"baseUrl"`
	WebSocketURL          string         `json:"websocketUrl"`
	Features              ServerFeatures `json:"features"`
	NotificationProviders []string       `json:"notificationProviders"`
}

type ServerFeatures struct {
	Chats         bool `json:"chats"`
	Messages      bool `json:"messages"`
	SendText      bool `json:"sendText"`
	Attachments   bool `json:"attachments"`
	WebSocket     bool `json:"websocket"`
	Devices       bool `json:"devices"`
	Notifications bool `json:"notifications"`
}

// SyncRuleJSON is a per-target sync/push rule (v0.11.3). targetKind is
// "chat" | "handle"; syncMode is "allow" | "block" | "inherit"; pushMode is
// "enabled" | "muted" | "inherit".
type SyncRuleJSON struct {
	TargetKind  string `json:"targetKind"`
	TargetValue string `json:"targetValue"`
	SyncMode    string `json:"syncMode"`
	PushMode    string `json:"pushMode"`
	CreatedAt   int64  `json:"createdAt"`
	UpdatedAt   int64  `json:"updatedAt"`
}

// SyncRulesResponse is the GET /api/sync/rules payload. defaultSyncPolicy is
// "allow_all" | "block_all"; defaultPushPolicy is "enabled" | "muted".
type SyncRulesResponse struct {
	DefaultSyncPolicy string         `json:"defaultSyncPolicy"`
	DefaultPushPolicy string         `json:"defaultPushPolicy"`
	Rules             []SyncRuleJSON `json:"rules"`
}

// ServerStatusResponse is the runtime control/status payload consumed by the
// native macOS companion app (see docs/spec-v0.10.0-mac-companion.md). It is
// intentionally read-only and local-control oriented; it never returns the
// bearer token or any push token.
type ServerStatusResponse struct {
	OK             bool                       `json:"ok"`
	Version        string                     `json:"version"`
	StartedAt      int64                      `json:"startedAt"`
	UptimeSeconds  int64                      `json:"uptimeSeconds"`
	Address        ServerAddressStatus        `json:"address"`
	Store          string                     `json:"store"`
	Auth           ServerAuthStatus           `json:"auth"`
	Sync           ServerSyncStatus           `json:"sync"`
	Notifications  ServerNotificationStatus   `json:"notifications"`
	Devices        ServerDevicesStatus        `json:"devices"`
	WebSocket      ServerWebSocketStatus      `json:"websocket"`
	Permissions    ServerPermissionStatus     `json:"permissions"`
	Capabilities   ServerCapabilities         `json:"capabilities"`
	MessageActions ServerMessageActionsStatus `json:"messageActions"`
	Backend        *ServerBackendStatus       `json:"backend,omitempty"`
}

// ServerMessageActionsStatus reports whether the bundled IMCore helper for the
// advanced iMessage actions (edit / unsend / delete) is present and usable, so
// the companion can show its status and clients can gate the actions. It mirrors
// imessage.Capabilities without coupling the store layer to that package.
type ServerMessageActionsStatus struct {
	Available bool `json:"available"`
	// State is one of missing | not_runnable | unsupported_selectors | ready.
	State             string `json:"state"`
	Edit              bool   `json:"edit"`
	Retract           bool   `json:"retract"`
	Delete            bool   `json:"delete"`
	Helper            string `json:"helper,omitempty"`
	Reason            string `json:"reason,omitempty"`
	RequiresMessages  bool   `json:"requiresMessages"`
	MinimumMacOS      string `json:"minimumMacOS,omitempty"`
	PlatformSupported bool   `json:"platformSupported"`
	PlatformWarning   string `json:"platformWarning,omitempty"`
}

// ServerCapabilities reports what the running chat.db schema supports, so
// clients/companion can know which update signals this Mac can actually produce.
// See docs/spec-v0.11.x-server-reliability.md.
type ServerCapabilities struct {
	Schema SchemaCapabilities `json:"schema"`
}

type ServerAddressStatus struct {
	Listen       string   `json:"listen"`
	BaseURL      string   `json:"baseUrl"`
	WebSocketURL string   `json:"websocketUrl"`
	LAN          []string `json:"lan"`
}

type ServerAuthStatus struct {
	Enabled bool `json:"enabled"`
}

type ServerSyncStatus struct {
	LoopEnabled      bool                   `json:"loopEnabled"`
	IntervalSeconds  int64                  `json:"intervalSeconds"`
	LastSyncAt       *int64                 `json:"lastSyncAt"`
	LastMessageRowID *int64                 `json:"lastMessageRowId"`
	Diagnostics      *ServerSyncDiagnostics `json:"diagnostics,omitempty"`
	// Settings echoes the live relay sync settings (backfill mode, per-chat
	// recent count, service scope) so the companion can prove what the running
	// backend actually loaded (C17). Mirrors relaydb.SyncSettings.
	Settings *ServerSyncSettings `json:"settings,omitempty"`
}

// ServerSyncSettings is the status-surface mirror of relaydb.SyncSettings
// (store cannot import relaydb — relaydb imports store).
type ServerSyncSettings struct {
	BackfillMode          string `json:"backfillMode"`
	RecentMessagesPerChat int    `json:"recentMessagesPerChat"`
	IncludeIMessage       bool   `json:"includeIMessage"`
	IncludeSMS            bool   `json:"includeSMS"`
	IncludeRCS            bool   `json:"includeRCS"`
	IncludeUnknown        bool   `json:"includeUnknown"`
	IncludeDebugInNormal  bool   `json:"includeDebugInNormal"`
	AllowSMSSend          bool   `json:"allowSmsSend"`
}

// ServerBackendStatus identifies the exact running backend binary (C17). Its
// purpose is to make a stale launch detectable: the companion compares this
// against the newest local build and warns on mismatch. ChatDBOpenOptions
// exposes the SQLite URI options so the absence of immutable=1 (the C15
// malformed-DB fix) is externally verifiable.
type ServerBackendStatus struct {
	Version           string `json:"version"`
	Commit            string `json:"commit"`
	BuildTime         string `json:"buildTime"`
	GoVersion         string `json:"goVersion"`
	OSArch            string `json:"osArch"`
	ExecutablePath    string `json:"executablePath"`
	ConfigPath        string `json:"configPath"`
	RelayDBPath       string `json:"relayDbPath"`
	ChatDBPath        string `json:"chatDbPath"`
	ChatDBOpenOptions string `json:"chatDbOpenOptions"`
	ChatDBImmutable   bool   `json:"chatDbImmutable"`
}

type ServerSyncDiagnostics struct {
	LastStartedAt           *int64 `json:"lastStartedAt,omitempty"`
	LastCompletedAt         *int64 `json:"lastCompletedAt,omitempty"`
	LastDurationMillis      int64  `json:"lastDurationMillis"`
	LastTriggerReason       string `json:"lastTriggerReason,omitempty"`
	LastInsertedMessages    int    `json:"lastInsertedMessages"`
	LastSyncedMessages      int    `json:"lastSyncedMessages"`
	LastRowsScanned         int    `json:"lastRowsScanned"`
	LastRenderableRows      int    `json:"lastRenderableRows"`
	LastHiddenDebugRows     int    `json:"lastHiddenDebugRows"`
	LastPerChatLimit        int    `json:"lastPerChatLimit"`
	LastBackfillMode        string `json:"lastBackfillMode,omitempty"`
	LastUpdatePassCount     int    `json:"lastUpdatePassCount"`
	LastUpdatePassSeeded    int    `json:"lastUpdatePassSeeded"`
	LastUnsentCount         int    `json:"lastUnsentCount"`
	LastScannedMessageRowID int64  `json:"lastScannedMessageRowId"`
	// C57 write-avoidance: rows actually written vs skipped as unchanged in the
	// last sync, and whether the throttled date-lookback recovery scan ran.
	LastChatsWritten       int     `json:"lastChatsWritten"`
	LastMessagesWritten    int     `json:"lastMessagesWritten"`
	LastAttachmentsWritten int     `json:"lastAttachmentsWritten"`
	LastRowsUnchanged      int     `json:"lastRowsUnchanged"`
	LastLookbackApplied    bool    `json:"lastLookbackApplied"`
	LastChatDBMtime        *int64  `json:"lastChatDbMtime,omitempty"`
	LastWALMtime           *int64  `json:"lastWalMtime,omitempty"`
	LastSHMMtime           *int64  `json:"lastShmMtime,omitempty"`
	LastSyncError          string  `json:"lastSyncError,omitempty"`
	PendingSendsCount      int     `json:"pendingSendsCount"`
	PendingTriggerCount    int     `json:"pendingTriggerCount"`
	LockRetryCount         int     `json:"lockRetryCount"`
	LateMatchedSendsCount  int     `json:"lateMatchedSendsCount"`
	LastEmittedEventType   string  `json:"lastEmittedEventType,omitempty"`
	LastEmittedChatGUID    *string `json:"lastEmittedChatGuid,omitempty"`
}

type ServerNotificationStatus struct {
	Enabled                     bool     `json:"enabled"`
	Provider                    string   `json:"provider"`
	Preview                     string   `json:"preview"`
	Providers                   []string `json:"providers"`
	Implemented                 []string `json:"implemented"`
	Stub                        []string `json:"stub"`
	FCMServiceAccountConfigured bool     `json:"fcmServiceAccountConfigured"`
	FCMClientConfigured         bool     `json:"fcmClientConfigured"`
}

type ServerDevicesStatus struct {
	Count int `json:"count"`
}

type ServerWebSocketStatus struct {
	Clients int `json:"clients"`
}

type ServerPermissionStatus struct {
	FullDiskAccess PermissionCheck `json:"fullDiskAccess"`
	Attachments    PermissionCheck `json:"attachments"`
	Automation     PermissionCheck `json:"automation"`
}

// PermissionCheck reports a single permission probe. Status is one of
// "ok", "denied", or "unknown".
type PermissionCheck struct {
	Status string `json:"status"`
	Detail string `json:"detail,omitempty"`
}

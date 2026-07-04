package relaydb

import "micagoserver/internal/store"

type SyncResult struct {
	Mode                     string
	PreviousLastMessageRowID int64
	NewLastMessageRowID      int64
	ChatsSynced              int
	MessagesSynced           int
	RenderableRowsInserted   int
	DebugOnlyRowsHidden      int
	AttachmentsSynced        int
	PerChatLimit             int
	RowsScanned              int
	LastMessageGUID          string
	LastMessageDateCreated   int64
	NewMessages              []store.MessageJSON
	NotificationEvents       []NotificationEvent
	// v0.11.x lookback update pass results.
	Updates       []MessageUpdate
	Unsent        []UnsentEvent
	UpdateScanned int
	UpdateSeeded  int
	// C57 write-avoidance counters. Written = rows actually inserted or updated;
	// Unchanged = conflict rows the DO UPDATE ... WHERE diff skipped (no write).
	ChatsWritten         int
	ChatsUnchanged       int
	MessagesWritten      int
	MessagesUnchanged    int
	AttachmentsWritten   int
	AttachmentsUnchanged int
	// LookbackApplied reports whether this run included the date-window recovery
	// scan (C57 throttles it to once per lookbackScanEvery at the app level).
	LookbackApplied bool
}

// MessageUpdate is an old-row state change detected by the lookback update pass
// (read/delivered/edited/send-error). Emitted as the WebSocket `message:update`
// event with the changed field names.
type MessageUpdate struct {
	Message store.MessageJSON
	Changed []string
}

// UnsentEvent is a retracted/unsent message detected by the update pass. Emitted
// as the WebSocket `message:unsend` event.
type UnsentEvent struct {
	GUID          string
	ChatGUID      string
	DateRetracted *int64
}

// UpdatePassResult holds the events produced by a single lookback update pass.
type UpdatePassResult struct {
	Updates []MessageUpdate
	Unsent  []UnsentEvent
	Scanned int
	Seeded  int
}

type NotificationEvent struct {
	ChatGUID       string
	ChatIdentifier *string
	ChatDisplay    *string
	IsGroup        bool
	Message        store.MessageJSON
}

func (e NotificationEvent) ChatLabel() string {
	if e.ChatDisplay != nil && *e.ChatDisplay != "" {
		return *e.ChatDisplay
	}
	if e.ChatIdentifier != nil {
		return *e.ChatIdentifier
	}
	return ""
}

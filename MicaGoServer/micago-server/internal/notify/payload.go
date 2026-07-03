package notify

type Notification struct {
	Type        string `json:"type"`
	MessageGUID string `json:"messageGuid"`
	ChatGUID    string `json:"chatGuid"`
	// SourceRowID is the chat.db ROWID of the message — the delta cursor (C21d).
	// The client uses it to run a precise catch-up after an FCM wake (C22), the
	// same "push is a wake/awareness signal, real data comes via sync" model as
	// BlueBubbles.
	SourceRowID       int64  `json:"sourceRowId"`
	Title             string `json:"title"`
	Body              string `json:"body"`
	SenderName        string `json:"senderName"`
	ConversationTitle string `json:"conversationTitle"`
	IsGroup           bool   `json:"isGroup"`
	// Handle is the raw sender address (phone/email). C31: carried so the client
	// can fall back to it for the notification title and resolve it against the
	// on-device address book — so a push never shows a GUID or an empty title.
	Handle      string `json:"handle"`
	PreviewMode string `json:"previewMode"`
	CreatedAt   int64  `json:"createdAt"`
}

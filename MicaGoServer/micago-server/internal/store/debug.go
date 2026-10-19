package store

import (
	"context"
	"database/sql"
	"fmt"
	"strings"

	"micagoserver/internal/timeutil"
)

// DebugAttachmentJSON is the attachment view used by the message debug
// inspector. It intentionally OMITS the on-disk local path and the full
// download URL (which can carry a token); presence is reported as a boolean so
// the inspector and its "Copy Debug JSON" export are safe to share.
type DebugAttachmentJSON struct {
	GUID                   string  `json:"guid"`
	Filename               *string `json:"filename"`
	TransferName           *string `json:"transferName"`
	MimeType               *string `json:"mimeType"`
	Uti                    *string `json:"uti"`
	AttachmentKind         string  `json:"attachmentKind"`
	IsVoiceMessage         bool    `json:"isVoiceMessage"`
	DisplayKind            string  `json:"displayKind"`
	IsPreviewableImage     bool    `json:"isPreviewableImage"`
	NeedsPreviewConversion bool    `json:"needsPreviewConversion"`
	TotalBytes             int64   `json:"totalBytes"`
	HasDownloadURL         bool    `json:"hasDownloadUrl"`
}

// DebugMessageJSON is a rich, debug-only view of a chat.db message used by the
// companion Message Inspector. It exposes iMessage-compatibility fields that the
// normal client API does not, to help diagnose why a message renders as
// unsupported on a client. It never contains the bearer token, local file
// paths, or credentials.
type DebugMessageJSON struct {
	GUID            string  `json:"guid"`
	RowID           int64   `json:"rowid"`
	ChatGUID        *string `json:"chatGuid"`
	ChatIdentifier  *string `json:"chatIdentifier"`
	ChatDisplayName *string `json:"chatDisplayName"`

	HandleID      *string `json:"handleId"`
	HandleService *string `json:"handleService"`
	IsFromMe      bool    `json:"isFromMe"`
	Service       *string `json:"service"`
	Account       *string `json:"account,omitempty"`

	Text              *string `json:"text"`
	TextLength        int     `json:"textLength"`
	HasAttributedBody bool    `json:"hasAttributedBody"`
	Subject           *string `json:"subject"`

	DateCreated   *int64 `json:"dateCreated"`
	DateDelivered *int64 `json:"dateDelivered"`
	DateRead      *int64 `json:"dateRead"`

	AssociatedMessageType  *int64  `json:"associatedMessageType"`
	AssociatedMessageGUID  *string `json:"associatedMessageGuid"`
	AssociatedMessageEmoji *string `json:"associatedMessageEmoji"`
	ThreadOriginatorGUID   *string `json:"threadOriginatorGuid"`
	ItemType               *int64  `json:"itemType"`
	GroupActionType        *int64  `json:"groupActionType"`
	GroupTitle             *string `json:"groupTitle"`
	BalloonBundleID        *string `json:"balloonBundleId"`
	ExpressiveSendStyleID  *string `json:"expressiveSendStyleId"`
	PayloadDataPresent     bool    `json:"payloadDataPresent"`
	Error                  *int64  `json:"error"`
	DateRetracted          *int64  `json:"dateRetracted"`
	DateEdited             *int64  `json:"dateEdited"`
	IsRetracted            bool    `json:"isRetracted"`
	IsEdited               bool    `json:"isEdited"`

	CacheHasAttachments bool                  `json:"cacheHasAttachments"`
	Attachments         []DebugAttachmentJSON `json:"attachments"`

	// Classification (heuristic; populated by AnnotateDebugMessage). Kind is the
	// best single guess; Candidates lists additional signals. See classify.go.
	Kind       string   `json:"kind"`
	Candidates []string `json:"candidates"`
}

// DebugListOptions are the structural (SQL-level) filters for the debug query.
// Text/type refinement and grouping are applied afterward in pure Go.
type DebugListOptions struct {
	ChatGUID  string // exact c.guid match; "" = any
	Sender    string // exact handle id match; "" = any
	Direction string // "incoming" | "outgoing" | "" (any)
	Limit     int
	Offset    int
}

// optionalDebugColumns are the version-sensitive message columns the inspector
// selects when present, in a fixed append order. Each carries the scan target
// wiring so a missing column never breaks the query on older schemas.
var optionalDebugColumns = []string{
	"associated_message_type",
	"associated_message_guid",
	"associated_message_emoji",
	"thread_originator_guid",
	"item_type",
	"group_action_type",
	"group_title",
	"balloon_bundle_id",
	"expressive_send_style_id",
	"payload_data",
	"error",
	"date_retracted",
	"date_edited",
	"account",
}

// ListDebugRecentMessages returns rich debug rows from chat.db. cols is the set
// of available `message` column names (see ProbeMessageColumns); version-
// sensitive columns are selected only when present. Rows are returned newest
// first; classification is NOT applied here (call AnnotateDebugMessage).
func (q *Queries) ListDebugRecentMessages(ctx context.Context, opts DebugListOptions, cols map[string]bool) ([]DebugMessageJSON, error) {
	limit := opts.Limit
	if limit <= 0 {
		limit = 100
	}
	if limit > 500 {
		limit = 500
	}
	offset := opts.Offset
	if offset < 0 {
		offset = 0
	}

	base := []string{
		"m.guid", "m.ROWID", "m.text", "m.attributedBody", "m.subject", "m.service",
		"m.date", "m.date_read", "m.date_delivered",
		"m.is_from_me", "m.is_read", "m.is_delivered", "m.cache_has_attachments",
		"h.id AS handle_id_value", "h.service AS handle_service",
		"c.guid AS chat_guid", "c.chat_identifier", "c.display_name",
	}
	// Which optional columns are actually present, in fixed order.
	present := make([]string, 0, len(optionalDebugColumns))
	for _, name := range optionalDebugColumns {
		if cols[name] {
			present = append(present, name)
			base = append(base, "m."+name)
		}
	}

	var sb strings.Builder
	sb.WriteString("SELECT DISTINCT\n  ")
	sb.WriteString(strings.Join(base, ",\n  "))
	sb.WriteString(`
FROM message AS m
JOIN chat_message_join AS cmj
  ON cmj.message_id = m.ROWID
JOIN chat AS c
  ON c.ROWID = cmj.chat_id
LEFT JOIN handle AS h
  ON h.ROWID = m.handle_id
`)

	clauses := make([]string, 0, 3)
	args := make([]any, 0, 5)
	if strings.TrimSpace(opts.ChatGUID) != "" {
		clauses = append(clauses, "c.guid = ?")
		args = append(args, opts.ChatGUID)
	}
	if strings.TrimSpace(opts.Sender) != "" {
		clauses = append(clauses, "h.id = ?")
		args = append(args, opts.Sender)
	}
	switch opts.Direction {
	case "incoming":
		clauses = append(clauses, "m.is_from_me = 0")
	case "outgoing":
		clauses = append(clauses, "m.is_from_me = 1")
	}
	if len(clauses) > 0 {
		sb.WriteString("WHERE " + joinClauses(clauses) + "\n")
	}
	sb.WriteString("ORDER BY m.date DESC\nLIMIT ? OFFSET ?;\n")
	args = append(args, limit, offset)

	rows, err := q.db.QueryContext(ctx, sb.String(), args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []DebugMessageJSON
	for rows.Next() {
		msg, err := scanDebugRow(rows, present)
		if err != nil {
			return nil, err
		}
		out = append(out, msg)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	return q.attachDebugAttachments(ctx, out)
}

func scanDebugRow(rows *sql.Rows, present []string) (DebugMessageJSON, error) {
	var (
		guid                          string
		rowID                         int64
		text                          *string
		attributedBody                []byte
		subject, service              *string
		dateRaw                       sql.NullInt64
		dateReadRaw, dateDeliveredRaw *int64
		// Bool-like ints are NULL-tolerant so a malformed/sparse row never breaks
		// the inspector (real chat.db rows are non-null).
		isFromMe, isRead, isDelivered sql.NullInt64
		hasAttachments                sql.NullInt64
		handleID, handleService       *string
		chatGUID, chatIdent, chatDisp *string
	)
	targets := []any{
		&guid, &rowID, &text, &attributedBody, &subject, &service,
		&dateRaw, &dateReadRaw, &dateDeliveredRaw,
		&isFromMe, &isRead, &isDelivered, &hasAttachments,
		&handleID, &handleService,
		&chatGUID, &chatIdent, &chatDisp,
	}
	_ = isRead
	_ = isDelivered

	// Optional scan holders, keyed by column name.
	intHolders := map[string]*sql.NullInt64{}
	strHolders := map[string]*sql.NullString{}
	var payloadHolder []byte
	for _, name := range present {
		switch name {
		case "associated_message_guid", "associated_message_emoji", "thread_originator_guid", "group_title",
			"balloon_bundle_id", "expressive_send_style_id", "account":
			h := &sql.NullString{}
			strHolders[name] = h
			targets = append(targets, h)
		case "payload_data":
			targets = append(targets, &payloadHolder)
		default: // associated_message_type, item_type, group_action_type, error
			h := &sql.NullInt64{}
			intHolders[name] = h
			targets = append(targets, h)
		}
	}

	if err := rows.Scan(targets...); err != nil {
		return DebugMessageJSON{}, fmt.Errorf("scan debug message row: %w", err)
	}

	extracted := ExtractMessageText(text, attributedBody)
	msg := DebugMessageJSON{
		GUID:                guid,
		RowID:               rowID,
		ChatGUID:            chatGUID,
		ChatIdentifier:      chatIdent,
		ChatDisplayName:     chatDisp,
		HandleID:            handleID,
		HandleService:       handleService,
		IsFromMe:            isFromMe.Int64 != 0,
		Service:             service,
		Text:                extracted,
		HasAttributedBody:   len(attributedBody) > 0,
		Subject:             subject,
		DateCreated:         timeutil.AppleMicrosToUnixMilli(dateRaw.Int64),
		DateDelivered:       timeutil.AppleMicrosToUnixMilliPtr(dateDeliveredRaw),
		DateRead:            timeutil.AppleMicrosToUnixMilliPtr(dateReadRaw),
		PayloadDataPresent:  len(payloadHolder) > 0,
		CacheHasAttachments: hasAttachments.Int64 != 0,
		Attachments:         []DebugAttachmentJSON{},
	}
	if extracted != nil {
		msg.TextLength = len(*extracted)
	}

	msg.AssociatedMessageType = nullInt(intHolders["associated_message_type"])
	msg.ItemType = nullInt(intHolders["item_type"])
	msg.GroupActionType = nullInt(intHolders["group_action_type"])
	msg.Error = nullInt(intHolders["error"])
	msg.AssociatedMessageGUID = nullStr(strHolders["associated_message_guid"])
	msg.AssociatedMessageEmoji = nullStr(strHolders["associated_message_emoji"])
	msg.ThreadOriginatorGUID = nullStr(strHolders["thread_originator_guid"])
	msg.GroupTitle = nullStr(strHolders["group_title"])
	msg.BalloonBundleID = nullStr(strHolders["balloon_bundle_id"])
	msg.ExpressiveSendStyleID = nullStr(strHolders["expressive_send_style_id"])
	msg.Account = nullStr(strHolders["account"])
	// Retract/edit dates are apple-epoch; convert to Unix ms and derive flags.
	if v := intHolders["date_retracted"]; v != nil && v.Valid {
		msg.DateRetracted = timeutil.AppleMicrosToUnixMilli(v.Int64)
		msg.IsRetracted = msg.DateRetracted != nil
	}
	if v := intHolders["date_edited"]; v != nil && v.Valid {
		msg.DateEdited = timeutil.AppleMicrosToUnixMilli(v.Int64)
		msg.IsEdited = msg.DateEdited != nil
	}

	return msg, nil
}

func nullInt(v *sql.NullInt64) *int64 {
	if v == nil || !v.Valid {
		return nil
	}
	n := v.Int64
	return &n
}

func nullStr(v *sql.NullString) *string {
	if v == nil || !v.Valid || strings.TrimSpace(v.String) == "" {
		return nil
	}
	s := v.String
	return &s
}

func (q *Queries) attachDebugAttachments(ctx context.Context, messages []DebugMessageJSON) ([]DebugMessageJSON, error) {
	if len(messages) == 0 {
		return messages, nil
	}
	guids := make([]string, 0, len(messages))
	for _, m := range messages {
		guids = append(guids, m.GUID)
	}
	rows, err := q.ListSyncAttachmentsForMessages(ctx, guids)
	if err != nil {
		return nil, err
	}
	grouped := make(map[string][]DebugAttachmentJSON, len(messages))
	for _, a := range rows {
		mime := InferMimeType(a.MimeType, a.Uti, a.TransferName, a.Filename)
		kind := AttachmentKind(a.IsSticker, mime, a.Uti, a.TransferName, a.Filename)
		voice := IsVoiceMessage(a.Uti, mime, a.TransferName, a.Filename)
		needsPreview := NeedsPreviewConversion(mime, a.Uti, a.TransferName, a.Filename)
		grouped[a.MessageGUID] = append(grouped[a.MessageGUID], DebugAttachmentJSON{
			GUID:                   a.GUID,
			Filename:               a.Filename,
			TransferName:           a.TransferName,
			MimeType:               mime,
			Uti:                    a.Uti,
			AttachmentKind:         kind,
			IsVoiceMessage:         voice,
			DisplayKind:            DisplayKind(kind, voice, needsPreview),
			IsPreviewableImage:     IsPreviewableImage(kind, mime, a.Uti, a.TransferName, a.Filename),
			NeedsPreviewConversion: needsPreview,
			TotalBytes:             a.TotalBytes,
			// Presence only — never the path or a tokenized URL.
			HasDownloadURL: strings.TrimSpace(a.GUID) != "",
		})
	}
	for i := range messages {
		if g := grouped[messages[i].GUID]; g != nil {
			messages[i].Attachments = g
		}
	}
	return messages, nil
}

package relaydb

import (
	"context"
	"database/sql"
	"fmt"
	"strconv"
	"strings"
	"time"

	"micagoserver/internal/store"
)

type syncSource interface {
	ListSyncChats(ctx context.Context) ([]store.SyncChatRow, error)
	ListSyncRecentMessages(ctx context.Context, limit int) ([]store.SyncMessageRow, error)
	ListSyncRecentMessagesSince(ctx context.Context, afterRowID int64, limit int) ([]store.SyncMessageRow, error)
	ListSyncAttachmentsForMessages(ctx context.Context, messageGUIDs []string) ([]store.SyncAttachmentRow, error)
}

type perChatSource interface {
	ListSyncRecentMessagesForChat(ctx context.Context, chatGUID string, limit int) ([]store.SyncMessageRow, error)
}

// byDateSource is an optional capability: a sync source that can scan a bounded
// date window (C11). The live chat.db source implements it; lightweight test
// fakes need not.
type byDateSource interface {
	ListSyncRecentMessagesByDate(ctx context.Context, afterUnixMilli int64, limit int) ([]store.SyncMessageRow, error)
}

// unionByGUID appends rows from b not already present (by GUID) in a.
func unionByGUID(a, b []store.SyncMessageRow) []store.SyncMessageRow {
	if len(b) == 0 {
		return a
	}
	seen := make(map[string]struct{}, len(a))
	for _, m := range a {
		seen[m.GUID] = struct{}{}
	}
	out := a
	for _, m := range b {
		if _, ok := seen[m.GUID]; ok {
			continue
		}
		seen[m.GUID] = struct{}{}
		out = append(out, m)
	}
	return out
}

func SyncOnce(ctx context.Context, source syncSource, relay *DB, limit int, lookback time.Duration) (SyncResult, error) {
	settings, err := relay.GetSyncSettings(ctx)
	if err != nil {
		return SyncResult{}, fmt.Errorf("get sync settings: %w", err)
	}
	lastRowIDValue, hasLastRowID, err := relay.GetSyncState("last_message_rowid")
	if err != nil {
		return SyncResult{}, fmt.Errorf("get last_message_rowid: %w", err)
	}

	var previousLastRowID int64
	if hasLastRowID {
		previousLastRowID, err = strconv.ParseInt(lastRowIDValue, 10, 64)
		if err != nil {
			return SyncResult{}, fmt.Errorf("parse last_message_rowid: %w", err)
		}
	}

	chats, err := source.ListSyncChats(ctx)
	if err != nil {
		return SyncResult{}, fmt.Errorf("list sync chats: %w", err)
	}

	mode := "incremental"
	lookbackApplied := false
	var messages []store.SyncMessageRow
	if !hasLastRowID {
		mode = "initial"
		messages, err = source.ListSyncRecentMessages(ctx, limit)
		if err != nil {
			return SyncResult{}, fmt.Errorf("list initial sync messages: %w", err)
		}
		if settings.BackfillMode == "per_chat_recent" || settings.BackfillMode == "hybrid" {
			if pc, ok := source.(perChatSource); ok {
				mode = settings.BackfillMode
				for _, chat := range chats {
					perChat, perErr := pc.ListSyncRecentMessagesForChat(ctx, chat.GUID, settings.RecentMessagesPerChat)
					if perErr != nil {
						return SyncResult{}, fmt.Errorf("list per-chat sync messages: %w", perErr)
					}
					messages = unionByGUID(messages, perChat)
				}
			}
		}
	} else {
		messages, err = source.ListSyncRecentMessagesSince(ctx, previousLastRowID, limit)
		if err != nil {
			return SyncResult{}, fmt.Errorf("list incremental sync messages: %w", err)
		}
		// C11: also scan a bounded date window (BlueBubbles-style) so rows the
		// ROWID watermark skipped under WAL/rowid races are recovered. Idempotent
		// — the relay upsert dedupes by guid and only truly-new rows broadcast.
		// C57: the caller throttles this (lookback 0 on most triggers); the rowid
		// watermark stays the primary new-message path on every sync.
		if lookback > 0 {
			if bd, ok := source.(byDateSource); ok {
				afterMs := time.Now().Add(-lookback).UnixMilli()
				dated, derr := bd.ListSyncRecentMessagesByDate(ctx, afterMs, limit)
				if derr != nil {
					return SyncResult{}, fmt.Errorf("list date-lookback messages: %w", derr)
				}
				messages = unionByGUID(messages, dated)
				lookbackApplied = true
			}
		}
	}

	// v0.11.3: evaluate sync rules. Blocked messages are NOT inserted/broadcast/
	// pushed, but the rowid watermark below still advances over the FULL set so
	// blocked messages are not re-scanned forever.
	snapshot, err := relay.LoadRuleSnapshot(ctx)
	if err != nil {
		return SyncResult{}, fmt.Errorf("load sync rules: %w", err)
	}
	chatService := make(map[string]*string, len(chats))
	for _, chat := range chats {
		chatService[chat.GUID] = chat.ServiceName
	}
	syncedMessages := make([]store.SyncMessageRow, 0, len(messages))
	for _, message := range messages {
		if message.Service == nil {
			message.Service = chatService[message.ChatGUID]
		}
		if snapshot.SyncAllowed(message.ChatGUID, message.HandleID) {
			syncedMessages = append(syncedMessages, message)
		}
	}

	messageGUIDs := make([]string, 0, len(syncedMessages))
	for _, message := range syncedMessages {
		messageGUIDs = append(messageGUIDs, message.GUID)
	}

	attachments, err := source.ListSyncAttachmentsForMessages(ctx, messageGUIDs)
	if err != nil {
		return SyncResult{}, fmt.Errorf("list sync attachments: %w", err)
	}

	tx, err := relay.sqlDB.BeginTx(ctx, nil)
	if err != nil {
		return SyncResult{}, err
	}
	defer tx.Rollback()

	now := time.Now().UnixMilli()
	chatsWritten, chatsUnchanged, err := upsertChatsTx(tx, chats, now)
	if err != nil {
		return SyncResult{}, err
	}
	insertedGUIDs, messagesWritten, messagesUnchanged, err := upsertMessagesTx(tx, syncedMessages, now)
	if err != nil {
		return SyncResult{}, err
	}
	attachmentsWritten, attachmentsUnchanged, err := upsertAttachmentsTx(tx, attachments, now)
	if err != nil {
		return SyncResult{}, err
	}

	result := SyncResult{
		Mode:                     mode,
		PreviousLastMessageRowID: previousLastRowID,
		NewLastMessageRowID:      previousLastRowID,
		ChatsSynced:              len(chats),
		MessagesSynced:           len(messages),
		RowsScanned:              len(messages),
		PerChatLimit:             settings.RecentMessagesPerChat,
		AttachmentsSynced:        len(attachments),
		ChatsWritten:             chatsWritten,
		ChatsUnchanged:           chatsUnchanged,
		MessagesWritten:          messagesWritten,
		MessagesUnchanged:        messagesUnchanged,
		AttachmentsWritten:       attachmentsWritten,
		AttachmentsUnchanged:     attachmentsUnchanged,
		LookbackApplied:          lookbackApplied,
	}
	for _, message := range syncedMessages {
		if store.DebugOnlyForSyncRow(message) {
			result.DebugOnlyRowsHidden++
		} else {
			result.RenderableRowsInserted++
		}
	}
	for _, message := range messages {
		if message.SourceRowID > result.NewLastMessageRowID {
			result.NewLastMessageRowID = message.SourceRowID
			result.LastMessageGUID = message.GUID
			if message.DateCreated != nil {
				result.LastMessageDateCreated = *message.DateCreated
			} else {
				result.LastMessageDateCreated = 0
			}
		}
	}

	if err := setSyncStateTx(tx, "last_sync_at", strconv.FormatInt(now, 10)); err != nil {
		return SyncResult{}, err
	}
	if result.NewLastMessageRowID > previousLastRowID {
		if err := setSyncStateTx(tx, "last_message_rowid", strconv.FormatInt(result.NewLastMessageRowID, 10)); err != nil {
			return SyncResult{}, err
		}
	}
	if result.LastMessageGUID != "" {
		if err := setSyncStateTx(tx, "last_message_guid", result.LastMessageGUID); err != nil {
			return SyncResult{}, err
		}
		if err := setSyncStateTx(tx, "last_message_date_created", strconv.FormatInt(result.LastMessageDateCreated, 10)); err != nil {
			return SyncResult{}, err
		}
	}

	if err := tx.Commit(); err != nil {
		return SyncResult{}, err
	}

	if len(insertedGUIDs) > 0 {
		result.NewMessages, err = relay.GetMessagesByGUIDs(ctx, insertedGUIDs)
		if err != nil {
			return SyncResult{}, err
		}
		// C12: notifications fire only for renderable rows — a freshly-synced
		// debug-only/noise row must never raise a notification (or, via the
		// realtime broadcast, land in the normal client thread). result.NewMessages
		// itself stays raw so send-reconciliation and the rowid watermark are
		// unaffected; the realtime broadcaster applies the same renderable filter.
		result.NotificationEvents = buildNotificationEvents(store.FilterRenderableMessages(result.NewMessages), syncedMessages, chats, snapshot)
	}

	return result, nil
}

func buildNotificationEvents(messages []store.MessageJSON, rows []store.SyncMessageRow, chats []store.SyncChatRow, snapshot RuleSnapshot) []NotificationEvent {
	if len(messages) == 0 {
		return nil
	}
	messageRows := make(map[string]store.SyncMessageRow, len(rows))
	for _, row := range rows {
		messageRows[row.GUID] = row
	}
	chatRows := make(map[string]store.SyncChatRow, len(chats))
	for _, chat := range chats {
		chatRows[chat.GUID] = chat
	}

	events := make([]NotificationEvent, 0, len(messages))
	for _, message := range messages {
		row, ok := messageRows[message.GUID]
		if !ok {
			continue
		}
		// v0.11.3: muted (but synced) messages are excluded from push dispatch.
		if !snapshot.PushEnabled(row.ChatGUID, row.HandleID) {
			continue
		}
		chat := chatRows[row.ChatGUID]
		events = append(events, NotificationEvent{
			ChatGUID:       row.ChatGUID,
			ChatIdentifier: chat.ChatIdentifier,
			ChatDisplay:    chat.DisplayName,
			IsGroup:        isGroupChat(chat.GUID, syncChatStyle(chat.Style), chat.ParticipantCount),
			Message:        message,
		})
	}
	return events
}

func syncChatStyle(v *int64) sql.NullInt64 {
	if v == nil {
		return sql.NullInt64{}
	}
	return sql.NullInt64{Int64: *v, Valid: true}
}

// upsertChatsTx writes chats with a write-avoidance guard (C57): the DO UPDATE
// only fires when a content column actually differs, so the every-sync pass
// over the full chat list stops rewriting identical rows (and stops bumping
// updated_at, which is only an ORDER BY tiebreaker) every 5 seconds.
// Returns (written, unchanged) row counts.
func upsertChatsTx(tx *sql.Tx, chats []store.SyncChatRow, updatedAt int64) (int, int, error) {
	stmt, err := tx.Prepare(`
INSERT INTO chats (
	guid, chat_identifier, service_name, display_name, is_archived, style, participant_count, participants, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(guid) DO UPDATE SET
	chat_identifier = excluded.chat_identifier,
	service_name = excluded.service_name,
	display_name = excluded.display_name,
	is_archived = excluded.is_archived,
	style = excluded.style,
	participant_count = excluded.participant_count,
	participants = excluded.participants,
	updated_at = excluded.updated_at
WHERE chats.chat_identifier IS NOT excluded.chat_identifier
	OR chats.service_name IS NOT excluded.service_name
	OR chats.display_name IS NOT excluded.display_name
	OR chats.is_archived IS NOT excluded.is_archived
	OR chats.style IS NOT excluded.style
	OR chats.participant_count IS NOT excluded.participant_count
	OR chats.participants IS NOT excluded.participants;
`)
	if err != nil {
		return 0, 0, err
	}
	defer stmt.Close()

	written, unchanged := 0, 0
	for _, chat := range chats {
		res, err := stmt.Exec(
			chat.GUID,
			chat.ChatIdentifier,
			chat.ServiceName,
			chat.DisplayName,
			boolToInt(chat.IsArchived),
			chat.Style,
			chat.ParticipantCount,
			encodeParticipants(chat.Participants),
			updatedAt,
		)
		if err != nil {
			return written, unchanged, err
		}
		affected, err := res.RowsAffected()
		if err != nil {
			return written, unchanged, err
		}
		if affected > 0 {
			written++
		} else {
			unchanged++
		}
	}

	return written, unchanged, nil
}

func encodeParticipants(participants []string) string {
	clean := make([]string, 0, len(participants))
	for _, participant := range participants {
		if p := strings.TrimSpace(participant); p != "" {
			clean = append(clean, p)
		}
	}
	return strings.Join(clean, "\x1f")
}

// existingMessageGUIDsTx returns the subset of guids already present, in one
// chunked IN query instead of a per-row SELECT (C57).
func existingMessageGUIDsTx(tx *sql.Tx, messages []store.SyncMessageRow) (map[string]struct{}, error) {
	existing := make(map[string]struct{}, len(messages))
	const chunkSize = 500 // stay under SQLite's bound-variable limit
	for start := 0; start < len(messages); start += chunkSize {
		end := start + chunkSize
		if end > len(messages) {
			end = len(messages)
		}
		chunk := messages[start:end]
		placeholders := strings.TrimSuffix(strings.Repeat("?,", len(chunk)), ",")
		args := make([]any, len(chunk))
		for i, message := range chunk {
			args[i] = message.GUID
		}
		rows, err := tx.Query(`SELECT guid FROM messages WHERE guid IN (`+placeholders+`)`, args...)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var guid string
			if err := rows.Scan(&guid); err != nil {
				rows.Close()
				return nil, err
			}
			existing[guid] = struct{}{}
		}
		if err := rows.Err(); err != nil {
			rows.Close()
			return nil, err
		}
		rows.Close()
	}
	return existing, nil
}

// upsertMessagesTx writes messages with a write-avoidance guard (C57). The
// incremental sync re-feeds the date-lookback window on every pass, so most
// conflict rows are byte-identical — the DO UPDATE's WHERE diff turns those
// into no-writes (RowsAffected 0) instead of constant WAL churn.
// Returns (insertedGUIDs, written, unchanged).
func upsertMessagesTx(tx *sql.Tx, messages []store.SyncMessageRow, createdAt int64) ([]string, int, int, error) {
	existing, err := existingMessageGUIDsTx(tx, messages)
	if err != nil {
		return nil, 0, 0, err
	}

	stmt, err := tx.Prepare(`
INSERT INTO messages (
	guid, chat_guid, source_rowid, text, subject, service, account, date_created, date_read, date_delivered,
	is_from_me, is_read, is_delivered, handle_id, handle_service, cache_has_attachments, created_at,
	has_attributed_body, associated_message_type, associated_message_guid, thread_originator_guid, item_type,
	group_action_type, group_title, balloon_bundle_id, expressive_send_style_id, payload_data_present,
	is_debug_only, is_reaction
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(guid) DO UPDATE SET
	chat_guid = excluded.chat_guid,
	source_rowid = excluded.source_rowid,
	text = excluded.text,
	subject = excluded.subject,
	service = excluded.service,
	account = excluded.account,
	date_created = excluded.date_created,
	date_read = excluded.date_read,
	date_delivered = excluded.date_delivered,
	is_from_me = excluded.is_from_me,
	is_read = excluded.is_read,
	is_delivered = excluded.is_delivered,
	handle_id = excluded.handle_id,
	handle_service = excluded.handle_service,
	cache_has_attachments = excluded.cache_has_attachments,
	has_attributed_body = excluded.has_attributed_body,
	associated_message_type = excluded.associated_message_type,
	associated_message_guid = excluded.associated_message_guid,
	thread_originator_guid = excluded.thread_originator_guid,
	item_type = excluded.item_type,
	group_action_type = excluded.group_action_type,
	group_title = excluded.group_title,
	balloon_bundle_id = excluded.balloon_bundle_id,
	expressive_send_style_id = excluded.expressive_send_style_id,
	payload_data_present = excluded.payload_data_present,
	is_debug_only = excluded.is_debug_only,
	is_reaction = excluded.is_reaction
WHERE messages.chat_guid IS NOT excluded.chat_guid
	OR messages.source_rowid IS NOT excluded.source_rowid
	OR messages.text IS NOT excluded.text
	OR messages.subject IS NOT excluded.subject
	OR messages.service IS NOT excluded.service
	OR messages.account IS NOT excluded.account
	OR messages.date_created IS NOT excluded.date_created
	OR messages.date_read IS NOT excluded.date_read
	OR messages.date_delivered IS NOT excluded.date_delivered
	OR messages.is_from_me IS NOT excluded.is_from_me
	OR messages.is_read IS NOT excluded.is_read
	OR messages.is_delivered IS NOT excluded.is_delivered
	OR messages.handle_id IS NOT excluded.handle_id
	OR messages.handle_service IS NOT excluded.handle_service
	OR messages.cache_has_attachments IS NOT excluded.cache_has_attachments
	OR messages.has_attributed_body IS NOT excluded.has_attributed_body
	OR messages.associated_message_type IS NOT excluded.associated_message_type
	OR messages.associated_message_guid IS NOT excluded.associated_message_guid
	OR messages.thread_originator_guid IS NOT excluded.thread_originator_guid
	OR messages.item_type IS NOT excluded.item_type
	OR messages.group_action_type IS NOT excluded.group_action_type
	OR messages.group_title IS NOT excluded.group_title
	OR messages.balloon_bundle_id IS NOT excluded.balloon_bundle_id
	OR messages.expressive_send_style_id IS NOT excluded.expressive_send_style_id
	OR messages.payload_data_present IS NOT excluded.payload_data_present
	OR messages.is_debug_only IS NOT excluded.is_debug_only
	OR messages.is_reaction IS NOT excluded.is_reaction;
`)
	if err != nil {
		return nil, 0, 0, err
	}
	defer stmt.Close()

	insertedGUIDs := make([]string, 0, len(messages))
	written, unchanged := 0, 0
	for _, message := range messages {
		_, alreadyExists := existing[message.GUID]
		isNew := !alreadyExists
		res, err := stmt.Exec(
			message.GUID,
			message.ChatGUID,
			message.SourceRowID,
			message.Text,
			message.Subject,
			message.Service,
			message.Account,
			message.DateCreated,
			message.DateRead,
			message.DateDelivered,
			boolToInt(message.IsFromMe),
			boolToInt(message.IsRead),
			boolToInt(message.IsDelivered),
			message.HandleID,
			message.HandleService,
			boolToInt(message.CacheHasAttachments),
			createdAt,
			boolToInt(message.HasAttributedBody),
			message.AssociatedMessageType,
			message.AssociatedMessageGUID,
			message.ThreadOriginatorGUID,
			message.ItemType,
			message.GroupActionType,
			message.GroupTitle,
			message.BalloonBundleID,
			message.ExpressiveSendStyleID,
			boolToInt(message.PayloadDataPresent),
			boolToInt(store.DebugOnlyForSyncRow(message)),
			boolToInt(store.IsReactionForSyncRow(message)),
		)
		if err != nil {
			return nil, written, unchanged, err
		}
		affected, err := res.RowsAffected()
		if err != nil {
			return nil, written, unchanged, err
		}
		if affected > 0 {
			written++
		} else {
			unchanged++
		}
		if isNew {
			insertedGUIDs = append(insertedGUIDs, message.GUID)
		}
	}

	return insertedGUIDs, written, unchanged, nil
}

// upsertAttachmentsTx writes attachments with a write-avoidance guard (C57).
// created_at is insert-only now: rows without a source timestamp used the
// `now` fallback, so re-upserting them every sync both rewrote the row and
// shifted the (created_at, guid) ordering the C49 identity dedup keys on.
// Returns (written, unchanged).
func upsertAttachmentsTx(tx *sql.Tx, attachments []store.SyncAttachmentRow, createdAt int64) (int, int, error) {
	stmt, err := tx.Prepare(`
INSERT INTO attachments (
	guid, message_guid, filename, mime_type, transfer_name, total_bytes, local_path, is_outgoing, hide_attachment, created_at, uti, is_sticker
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(guid) DO UPDATE SET
	message_guid = excluded.message_guid,
	filename = excluded.filename,
	mime_type = excluded.mime_type,
	transfer_name = excluded.transfer_name,
	total_bytes = excluded.total_bytes,
	local_path = excluded.local_path,
	is_outgoing = excluded.is_outgoing,
	hide_attachment = excluded.hide_attachment,
	uti = excluded.uti,
	is_sticker = excluded.is_sticker
WHERE attachments.message_guid IS NOT excluded.message_guid
	OR attachments.filename IS NOT excluded.filename
	OR attachments.mime_type IS NOT excluded.mime_type
	OR attachments.transfer_name IS NOT excluded.transfer_name
	OR attachments.total_bytes IS NOT excluded.total_bytes
	OR attachments.local_path IS NOT excluded.local_path
	OR attachments.is_outgoing IS NOT excluded.is_outgoing
	OR attachments.hide_attachment IS NOT excluded.hide_attachment
	OR attachments.uti IS NOT excluded.uti
	OR attachments.is_sticker IS NOT excluded.is_sticker;
`)
	if err != nil {
		return 0, 0, err
	}
	defer stmt.Close()

	written, unchanged := 0, 0
	for _, attachment := range attachments {
		created := createdAt
		if attachment.CreatedAt != nil {
			created = *attachment.CreatedAt
		}
		res, err := stmt.Exec(
			attachment.GUID,
			attachment.MessageGUID,
			attachment.Filename,
			attachment.MimeType,
			attachment.TransferName,
			attachment.TotalBytes,
			attachment.LocalPath,
			boolToInt(attachment.IsOutgoing),
			boolToInt(attachment.HideAttachment),
			created,
			attachment.Uti,
			boolToInt(attachment.IsSticker),
		)
		if err != nil {
			return written, unchanged, err
		}
		affected, err := res.RowsAffected()
		if err != nil {
			return written, unchanged, err
		}
		if affected > 0 {
			written++
		} else {
			unchanged++
		}
	}

	return written, unchanged, nil
}

func setSyncStateTx(tx *sql.Tx, key, value string) error {
	_, err := tx.Exec(`
INSERT INTO sync_state (key, value)
VALUES (?, ?)
ON CONFLICT(key) DO UPDATE SET value = excluded.value;
`, key, value)
	return err
}

func boolToInt(v bool) int {
	if v {
		return 1
	}
	return 0
}

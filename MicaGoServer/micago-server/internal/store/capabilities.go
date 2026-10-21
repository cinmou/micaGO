package store

import (
	"context"
	"database/sql"
	"fmt"
)

// SchemaCapabilities reports which version-sensitive chat.db columns exist on
// the running macOS, so query builders can select them only when present and
// degrade gracefully otherwise. See docs/ARCHITECTURE.md.
type SchemaCapabilities struct {
	EditedMessages     bool `json:"editedMessages"`     // message.date_edited
	UnsentMessages     bool `json:"unsentMessages"`     // message.date_retracted
	ReadStatus         bool `json:"readStatus"`         // message.date_read
	DeliveredStatus    bool `json:"deliveredStatus"`    // message.date_delivered
	SendError          bool `json:"sendError"`          // message.error
	GroupActions       bool `json:"groupActions"`       // message.item_type + group_action_type
	AttachmentMetadata bool `json:"attachmentMetadata"` // attachment.mime_type + transfer_name + total_bytes
}

// probedTables are the only tables ProbeCapabilities will inspect. PRAGMA cannot
// bind parameters, so table names are interpolated; restricting to this
// allowlist keeps that safe.
var probedTables = map[string]bool{
	"message":    true,
	"chat":       true,
	"attachment": true,
}

// ProbeCapabilities inspects the chat.db schema via PRAGMA table_info and reports
// which version-sensitive columns are available. A missing table simply yields
// an empty column set (no error), so capabilities degrade to false rather than
// crashing.
func ProbeCapabilities(ctx context.Context, db *sql.DB) (SchemaCapabilities, error) {
	messageCols, err := tableColumns(ctx, db, "message")
	if err != nil {
		return SchemaCapabilities{}, err
	}
	attachmentCols, err := tableColumns(ctx, db, "attachment")
	if err != nil {
		return SchemaCapabilities{}, err
	}

	return SchemaCapabilities{
		EditedMessages:  messageCols["date_edited"],
		UnsentMessages:  messageCols["date_retracted"],
		ReadStatus:      messageCols["date_read"],
		DeliveredStatus: messageCols["date_delivered"],
		SendError:       messageCols["error"],
		GroupActions:    messageCols["item_type"] && messageCols["group_action_type"],
		AttachmentMetadata: attachmentCols["mime_type"] &&
			attachmentCols["transfer_name"] &&
			attachmentCols["total_bytes"],
	}, nil
}

// ProbeMessageColumns returns the set of column names present on the chat.db
// `message` table. The debug message inspector uses this to select
// version-sensitive iMessage columns (associated_message_type, item_type,
// balloon_bundle_id, …) only when they exist, degrading gracefully on older
// schemas instead of failing the query. A missing table yields an empty set.
func ProbeMessageColumns(ctx context.Context, db *sql.DB) (map[string]bool, error) {
	return tableColumns(ctx, db, "message")
}

// tableColumns returns the set of column names for a table via
// PRAGMA table_info. A non-existent table returns an empty set with no error.
func tableColumns(ctx context.Context, db *sql.DB, table string) (map[string]bool, error) {
	if !probedTables[table] {
		return nil, fmt.Errorf("refusing to probe non-allowlisted table %q", table)
	}

	rows, err := db.QueryContext(ctx, fmt.Sprintf("PRAGMA table_info(%s)", table))
	if err != nil {
		return nil, fmt.Errorf("probe %s columns: %w", table, err)
	}
	defer rows.Close()

	cols := make(map[string]bool)
	for rows.Next() {
		// PRAGMA table_info columns: cid, name, type, notnull, dflt_value, pk
		var (
			cid       int
			name      string
			colType   sql.NullString
			notNull   int
			dfltValue sql.NullString
			pk        int
		)
		if err := rows.Scan(&cid, &name, &colType, &notNull, &dfltValue, &pk); err != nil {
			return nil, fmt.Errorf("scan %s column info: %w", table, err)
		}
		cols[name] = true
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate %s columns: %w", table, err)
	}
	return cols, nil
}

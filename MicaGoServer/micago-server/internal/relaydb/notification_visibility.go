package relaydb

import "context"

// Consult synchronized state immediately before dispatching delayed pushes.
func (db *DB) VisibleNotificationEvents(ctx context.Context, events []NotificationEvent) ([]NotificationEvent, error) {
	tx, err := db.sqlDB.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	result := make([]NotificationEvent, 0, len(events))
	for _, event := range events {
		var hiddenChat, hiddenMessage bool
		var readThrough int64
		err = tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM chat_preferences WHERE chat_guid=? AND hidden=1), EXISTS(SELECT 1 FROM message_preferences WHERE message_key=? AND hidden=1), COALESCE((SELECT read_through FROM read_positions WHERE chat_guid=?),0)`, event.ChatGUID, event.ChatGUID+"\x1f"+event.Message.GUID, event.ChatGUID).Scan(&hiddenChat, &hiddenMessage, &readThrough)
		if err != nil {
			return nil, err
		}
		if hiddenChat || hiddenMessage {
			continue
		}
		if event.Message.DateCreated != nil && *event.Message.DateCreated > 0 && *event.Message.DateCreated <= readThrough {
			continue
		}
		result = append(result, event)
	}
	return result, tx.Commit()
}

package store

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
)

// MessageState captures the mutable, update-relevant fields of a message used to
// detect post-insert changes (edits, unsends, read/delivered, send errors). See
// docs/ARCHITECTURE.md. Fields are only meaningful when
// the corresponding SchemaCapabilities flag is set; absent capabilities leave
// them at their zero value and are excluded from comparison.
type MessageState struct {
	IsRead        bool
	DateRead      *int64
	IsDelivered   bool
	DateDelivered *int64
	DateEdited    *int64
	DateRetracted *int64
	ErrorCode     int64
}

// Changed-field names emitted to clients (Mica-native, camelCase). These are not
// BlueBubbles event field names.
const (
	ChangeIsRead        = "isRead"
	ChangeDateRead      = "dateRead"
	ChangeIsDelivered   = "isDelivered"
	ChangeDateDelivered = "dateDelivered"
	ChangeText          = "text"
	ChangeIsEdited      = "isEdited"
	ChangeDateEdited    = "dateEdited"
	ChangeSendError     = "sendError"
)

// Fingerprint returns a stable hash over only the fields enabled by caps, so an
// unchanged row produces an identical fingerprint across sync ticks and does not
// rebroadcast.
func (s MessageState) Fingerprint(caps SchemaCapabilities) string {
	h := sha256.New()
	if caps.ReadStatus {
		fmt.Fprintf(h, "r:%v:%s;", s.IsRead, fmtPtr(s.DateRead))
	}
	if caps.DeliveredStatus {
		fmt.Fprintf(h, "d:%v:%s;", s.IsDelivered, fmtPtr(s.DateDelivered))
	}
	if caps.EditedMessages {
		fmt.Fprintf(h, "e:%s;", fmtPtr(s.DateEdited))
	}
	if caps.UnsentMessages {
		fmt.Fprintf(h, "u:%s;", fmtPtr(s.DateRetracted))
	}
	if caps.SendError {
		fmt.Fprintf(h, "x:%d;", s.ErrorCode)
	}
	return hex.EncodeToString(h.Sum(nil))
}

// DiffMessageState returns the list of changed client-facing field names between
// two states (gated by caps) and whether the message was newly retracted.
func DiffMessageState(old, current MessageState, caps SchemaCapabilities) (changed []string, retracted bool) {
	if caps.ReadStatus {
		if old.IsRead != current.IsRead {
			changed = append(changed, ChangeIsRead)
		}
		if !int64PtrEqual(old.DateRead, current.DateRead) {
			changed = append(changed, ChangeDateRead)
		}
	}
	if caps.DeliveredStatus {
		if old.IsDelivered != current.IsDelivered {
			changed = append(changed, ChangeIsDelivered)
		}
		if !int64PtrEqual(old.DateDelivered, current.DateDelivered) {
			changed = append(changed, ChangeDateDelivered)
		}
	}
	if caps.EditedMessages && !int64PtrEqual(old.DateEdited, current.DateEdited) {
		// An edit changes the text and sets date_edited.
		changed = append(changed, ChangeIsEdited, ChangeDateEdited, ChangeText)
	}
	if caps.SendError && old.ErrorCode != current.ErrorCode {
		changed = append(changed, ChangeSendError)
	}
	if caps.UnsentMessages && isNewlySet(old.DateRetracted, current.DateRetracted) {
		retracted = true
	}
	return changed, retracted
}

func fmtPtr(v *int64) string {
	if v == nil {
		return "-"
	}
	return fmt.Sprintf("%d", *v)
}

func int64PtrEqual(a, b *int64) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
}

// isNewlySet reports whether current became set (or advanced) relative to old.
func isNewlySet(old, current *int64) bool {
	if current == nil || *current == 0 {
		return false
	}
	if old == nil || *old == 0 {
		return true
	}
	return *current > *old
}

package send

import "time"

// SendStatus is the lifecycle of a tracked outgoing send.
type SendStatus string

const (
	StatusPending         SendStatus = "pending"
	StatusSentUnconfirmed SendStatus = "sent_unconfirmed"
	StatusConfirmed       SendStatus = "confirmed"
	StatusFailed          SendStatus = "failed"
)

// PendingSend tracks one in-flight plain-text send while we wait for the
// matching outgoing row to appear in chat.db. OriginalMessage is preserved
// verbatim; NormalizedMessage is only a fuzzy match key (see normalize.go).
type PendingSend struct {
	TempGUID          string
	ChatGUID          string
	OriginalMessage   string
	NormalizedMessage string
	// SentAtUnixMilli is the lower bound (with a small backdated tolerance) used
	// to filter candidate outgoing rows by date.
	SentAtUnixMilli int64
	Timeout         time.Duration

	// Lifecycle bookkeeping (set/maintained by PendingSendManager).
	CreatedAt    time.Time
	Status       SendStatus
	MatchedGUID  string
	MatchedROWID int64
	FailReason   string
	RecoverUntil time.Time
}

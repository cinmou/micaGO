package send

import (
	"errors"
	"sync"
	"time"
)

var ErrDuplicateTempGUID = errors.New("duplicate tempGuid")

const defaultLateMatchWindow = 2 * time.Minute

// PendingSendManager tracks in-flight outgoing sends and which chat.db rows
// have already been claimed by a confirmation, so two concurrent sends of
// identical text never confirm against the same row.
type PendingSendManager struct {
	mu      sync.Mutex
	pending map[string]PendingSend
	// claimed maps a matched message GUID -> the tempGUID that claimed it.
	claimed map[string]string
}

type ReconcileCandidate struct {
	GUID        string
	ChatGUID    string
	Text        string
	DateCreated *int64
	IsFromMe    bool
}

func NewPendingSendManager() *PendingSendManager {
	return &PendingSendManager{
		pending: map[string]PendingSend{},
		claimed: map[string]string{},
	}
}

// Add registers a new pending send. It stamps CreatedAt/RecoverUntil/Status when
// they are unset so callers can pass a sparse record.
func (m *PendingSendManager) Add(p PendingSend) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if _, exists := m.pending[p.TempGUID]; exists {
		return ErrDuplicateTempGUID
	}
	if p.CreatedAt.IsZero() {
		p.CreatedAt = time.Now()
	}
	if p.RecoverUntil.IsZero() {
		p.RecoverUntil = p.CreatedAt.Add(defaultLateMatchWindow)
	}
	if p.Status == "" {
		p.Status = StatusPending
	}
	m.pending[p.TempGUID] = p
	return nil
}

// Remove deletes the pending send and releases any chat.db row it claimed.
func (m *PendingSendManager) Remove(tempGUID string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if p, ok := m.pending[tempGUID]; ok && p.MatchedGUID != "" {
		if owner, claimed := m.claimed[p.MatchedGUID]; claimed && owner == tempGUID {
			delete(m.claimed, p.MatchedGUID)
		}
	}
	delete(m.pending, tempGUID)
}

func (m *PendingSendManager) Has(tempGUID string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	_, exists := m.pending[tempGUID]
	return exists
}

// Resolve atomically claims a chat.db row for a pending send and marks it
// confirmed. It returns false when the row was already claimed by a different
// pending send (so the caller should keep looking for another candidate), or
// when the tempGUID is unknown.
func (m *PendingSendManager) Resolve(tempGUID, matchedGUID string, matchedROWID int64) bool {
	m.mu.Lock()
	defer m.mu.Unlock()

	p, ok := m.pending[tempGUID]
	if !ok {
		return false
	}
	if owner, claimed := m.claimed[matchedGUID]; claimed && owner != tempGUID {
		return false
	}
	m.claimed[matchedGUID] = tempGUID
	p.Status = StatusConfirmed
	p.MatchedGUID = matchedGUID
	p.MatchedROWID = matchedROWID
	m.pending[tempGUID] = p
	return true
}

// Reject marks a pending send failed with a short reason.
func (m *PendingSendManager) Reject(tempGUID, reason string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if p, ok := m.pending[tempGUID]; ok {
		p.Status = StatusFailed
		p.FailReason = reason
		m.pending[tempGUID] = p
	}
}

// MarkSentUnconfirmed keeps a send alive after AppleScript succeeded but the
// matching chat.db row did not appear before the foreground confirmation wait.
func (m *PendingSendManager) MarkSentUnconfirmed(tempGUID, reason string, recoverFor time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if p, ok := m.pending[tempGUID]; ok {
		p.Status = StatusSentUnconfirmed
		p.FailReason = reason
		if recoverFor > 0 {
			p.RecoverUntil = time.Now().Add(recoverFor)
		}
		m.pending[tempGUID] = p
	}
}

// ClaimedSnapshot returns a copy of the currently claimed message GUIDs so a
// matcher can exclude rows already taken by other in-flight sends.
func (m *PendingSendManager) ClaimedSnapshot() map[string]struct{} {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make(map[string]struct{}, len(m.claimed))
	for guid := range m.claimed {
		out[guid] = struct{}{}
	}
	return out
}

// ReconcileMessages attempts to late-match pending/unconfirmed sends against
// newly synced outgoing rows. It mirrors the foreground matcher but runs after
// normal sync passes so a delayed Messages DB insert can still replace the
// client's optimistic bubble.
func (m *PendingSendManager) ReconcileMessages(messages []ReconcileCandidate, now time.Time) []PendingSend {
	m.mu.Lock()
	defer m.mu.Unlock()

	var matched []PendingSend
	for _, message := range messages {
		if !message.IsFromMe || message.GUID == "" {
			continue
		}
		if _, claimed := m.claimed[message.GUID]; claimed {
			continue
		}
		chatGUID := message.ChatGUID
		text := NormalizeText(message.Text)
		for tempGUID, pending := range m.pending {
			if pending.Status == StatusConfirmed {
				continue
			}
			if !pending.RecoverUntil.IsZero() && now.After(pending.RecoverUntil) {
				continue
			}
			if chatGUID == "" || pending.ChatGUID != chatGUID {
				continue
			}
			if text == "" || pending.NormalizedMessage != text {
				continue
			}
			if message.DateCreated != nil && *message.DateCreated < pending.SentAtUnixMilli {
				continue
			}
			pending.Status = StatusConfirmed
			pending.MatchedGUID = message.GUID
			m.pending[tempGUID] = pending
			m.claimed[message.GUID] = tempGUID
			matched = append(matched, pending)
			break
		}
	}
	return matched
}

func (m *PendingSendManager) PendingCount() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.pending)
}

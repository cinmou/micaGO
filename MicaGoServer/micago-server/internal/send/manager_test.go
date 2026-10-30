package send

import (
	"testing"
	"time"
)

func TestPendingManagerAddStampsDefaults(t *testing.T) {
	m := NewPendingSendManager()
	if err := m.Add(PendingSend{TempGUID: "t1", Timeout: 15 * time.Second}); err != nil {
		t.Fatal(err)
	}
	p, ok := m.Get("t1")
	if !ok {
		t.Fatal("expected pending send present")
	}
	if p.Status != StatusPending {
		t.Fatalf("expected status pending, got %q", p.Status)
	}
	if p.CreatedAt.IsZero() {
		t.Fatal("expected CreatedAt stamped")
	}
	if !p.RecoverUntil.After(p.CreatedAt) {
		t.Fatal("expected late-match recovery window after CreatedAt")
	}
}

func TestPendingManagerResolveConfirmsAndClaims(t *testing.T) {
	m := NewPendingSendManager()
	_ = m.Add(PendingSend{TempGUID: "t1"})

	if ok := m.Resolve("t1", "msg-1", 42); !ok {
		t.Fatal("expected Resolve to succeed")
	}
	p, _ := m.Get("t1")
	if p.Status != StatusConfirmed || p.MatchedGUID != "msg-1" || p.MatchedROWID != 42 {
		t.Fatalf("unexpected resolved record: %+v", p)
	}
	if _, claimed := m.ClaimedSnapshot()["msg-1"]; !claimed {
		t.Fatal("expected msg-1 to be claimed")
	}
}

func TestPendingManagerResolveRejectsRowClaimedByAnother(t *testing.T) {
	m := NewPendingSendManager()
	_ = m.Add(PendingSend{TempGUID: "first"})
	_ = m.Add(PendingSend{TempGUID: "second"})

	if ok := m.Resolve("first", "msg-1", 0); !ok {
		t.Fatal("first claim should succeed")
	}
	if ok := m.Resolve("second", "msg-1", 0); ok {
		t.Fatal("second claim of the same row must fail")
	}
}

func TestPendingManagerRemoveReleasesClaim(t *testing.T) {
	m := NewPendingSendManager()
	_ = m.Add(PendingSend{TempGUID: "t1"})
	m.Resolve("t1", "msg-1", 0)
	m.Remove("t1")
	if _, claimed := m.ClaimedSnapshot()["msg-1"]; claimed {
		t.Fatal("expected claim released on Remove")
	}
}

func TestPendingManagerReject(t *testing.T) {
	m := NewPendingSendManager()
	_ = m.Add(PendingSend{TempGUID: "t1"})
	m.Reject("t1", "send_failed")
	p, _ := m.Get("t1")
	if p.Status != StatusFailed || p.FailReason != "send_failed" {
		t.Fatalf("unexpected rejected record: %+v", p)
	}
}

func TestPendingManagerMarkSentUnconfirmedKeepsRecord(t *testing.T) {
	m := NewPendingSendManager()
	_ = m.Add(PendingSend{TempGUID: "t1"})
	m.MarkSentUnconfirmed("t1", "send_confirmation_timeout", time.Minute)
	p, ok := m.Get("t1")
	if !ok {
		t.Fatal("expected pending record kept")
	}
	if p.Status != StatusSentUnconfirmed || p.FailReason != "send_confirmation_timeout" {
		t.Fatalf("unexpected unconfirmed record: %+v", p)
	}
}

func TestPendingManagerReconcileMessagesLateMatchesOutgoing(t *testing.T) {
	m := NewPendingSendManager()
	sentAt := time.Now().Add(-time.Second).UnixMilli()
	_ = m.Add(PendingSend{
		TempGUID:          "tmp-1",
		ChatGUID:          "chat-1",
		NormalizedMessage: NormalizeText("Hello there"),
		SentAtUnixMilli:   sentAt,
		Status:            StatusSentUnconfirmed,
	})
	matches := m.ReconcileMessages([]ReconcileCandidate{{
		GUID:        "real-1",
		ChatGUID:    "chat-1",
		Text:        "hello there",
		DateCreated: ptrInt64(time.Now().UnixMilli()),
		IsFromMe:    true,
	}}, time.Now())
	if len(matches) != 1 || matches[0].TempGUID != "tmp-1" {
		t.Fatalf("expected late match, got %+v", matches)
	}
	p, _ := m.Get("tmp-1")
	if p.Status != StatusConfirmed || p.MatchedGUID != "real-1" {
		t.Fatalf("unexpected reconciled record: %+v", p)
	}
}

func TestPendingManagerReconcileMessagesDoesNotMatchDifferentOutgoing(t *testing.T) {
	m := NewPendingSendManager()
	_ = m.Add(PendingSend{
		TempGUID:          "tmp-1",
		ChatGUID:          "chat-1",
		NormalizedMessage: NormalizeText("Hello"),
		SentAtUnixMilli:   time.Now().Add(-time.Second).UnixMilli(),
		Status:            StatusSentUnconfirmed,
	})
	matches := m.ReconcileMessages([]ReconcileCandidate{{
		GUID:        "real-1",
		ChatGUID:    "chat-2",
		Text:        "Hello",
		DateCreated: ptrInt64(time.Now().UnixMilli()),
		IsFromMe:    true,
	}}, time.Now())
	if len(matches) != 0 {
		t.Fatalf("expected no match, got %+v", matches)
	}
}

func ptrInt64(v int64) *int64 { return &v }

func TestPendingManagerRejectsDuplicateTempGUID(t *testing.T) {
	manager := NewPendingSendManager()
	pending := PendingSend{TempGUID: "dup"}

	if err := manager.Add(pending); err != nil {
		t.Fatal(err)
	}
	if err := manager.Add(pending); err != ErrDuplicateTempGUID {
		t.Fatalf("expected ErrDuplicateTempGUID, got %v", err)
	}
}

func TestPendingManagerRemoveCleansUp(t *testing.T) {
	manager := NewPendingSendManager()
	if err := manager.Add(PendingSend{TempGUID: "one"}); err != nil {
		t.Fatal(err)
	}
	manager.Remove("one")
	if manager.Has("one") {
		t.Fatal("expected pending send to be removed")
	}
}

// Get returns a copy of the pending send and whether it exists.
func (m *PendingSendManager) Get(tempGUID string) (PendingSend, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	p, ok := m.pending[tempGUID]
	return p, ok
}

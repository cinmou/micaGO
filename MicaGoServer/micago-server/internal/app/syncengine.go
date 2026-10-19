package app

import (
	"context"
	"strings"
	"sync"
	"time"
)

// SyncEngine serializes and coalesces sync triggers (C11). A single worker runs
// syncs one at a time (never overlapping); triggers that arrive while a sync is
// running are coalesced into exactly one follow-up run (the latest reason wins),
// so a burst of WAL/mtime/send triggers never piles up and never gets dropped.
// DB-lock errors are retried with backoff inside a run.
type SyncEngine struct {
	// run performs one sync for the given trigger reason. Returns an error only
	// for genuine failures (used to drive lock-retry).
	run func(ctx context.Context, reason string) error

	// isLocked reports whether an error is a transient DB-lock/busy condition.
	isLocked func(error) bool

	// onLockRetry is called each time a run is retried due to a DB lock.
	onLockRetry func()

	maxLockRetries int
	lockBackoff    time.Duration

	wake chan struct{}

	mu            sync.Mutex
	pending       bool
	pendingReason string
	pendingCount  int // total triggers coalesced (diagnostic)
}

func NewSyncEngine(run func(ctx context.Context, reason string) error) *SyncEngine {
	return &SyncEngine{
		run:            run,
		isLocked:       isDBLockedError,
		maxLockRetries: 4,
		lockBackoff:    150 * time.Millisecond,
		wake:           make(chan struct{}, 1),
	}
}

// PendingCount returns the total number of coalesced triggers observed.
func (e *SyncEngine) PendingCount() int {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.pendingCount
}

// Start launches the worker. Returns when ctx is cancelled.
func (e *SyncEngine) Start(ctx context.Context) {
	go e.worker(ctx)
}

// Trigger requests a sync for [reason]. Non-blocking: if a sync is in progress,
// the request is coalesced (latest reason wins) and will run once afterward.
func (e *SyncEngine) Trigger(reason string) {
	e.mu.Lock()
	e.pending = true
	e.pendingReason = reason
	e.pendingCount++
	e.mu.Unlock()
	select {
	case e.wake <- struct{}{}:
	default: // a wake is already queued; the worker will see the pending flag
	}
}

// TriggerBurst fires [reason] [n] times spaced by [interval] (e.g. the
// short-poll burst after a send so a delayed outgoing DB row is caught quickly).
// The engine coalesces, so this never causes overlapping syncs.
func (e *SyncEngine) TriggerBurst(ctx context.Context, reason string, n int, interval time.Duration) {
	go func() {
		for i := 0; i < n; i++ {
			e.Trigger(reason)
			select {
			case <-ctx.Done():
				return
			case <-time.After(interval):
			}
		}
	}()
}

func (e *SyncEngine) worker(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-e.wake:
		}
		for {
			e.mu.Lock()
			if !e.pending {
				e.mu.Unlock()
				break
			}
			reason := e.pendingReason
			e.pending = false
			e.mu.Unlock()

			e.runWithBackoff(ctx, reason)
			if ctx.Err() != nil {
				return
			}
		}
	}
}

func (e *SyncEngine) runWithBackoff(ctx context.Context, reason string) {
	backoff := e.lockBackoff
	for attempt := 0; ; attempt++ {
		err := e.run(ctx, reason)
		if err == nil || !e.isLocked(err) || attempt >= e.maxLockRetries {
			return
		}
		if e.onLockRetry != nil {
			e.onLockRetry()
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		backoff *= 2
	}
}

// isDBLockedError reports whether err looks like a transient SQLite
// lock/busy condition that is worth retrying.
func isDBLockedError(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "database is locked") ||
		strings.Contains(msg, "database table is locked") ||
		strings.Contains(msg, "sqlite_busy") ||
		strings.Contains(msg, "busy")
}

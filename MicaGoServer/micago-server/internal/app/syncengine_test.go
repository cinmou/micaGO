package app

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatal("condition not met within timeout")
}

func TestSyncEngineNeverOverlaps(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var concurrent, maxConcurrent int32
	var runs int32
	e := NewSyncEngine(func(ctx context.Context, reason string) error {
		c := atomic.AddInt32(&concurrent, 1)
		for {
			m := atomic.LoadInt32(&maxConcurrent)
			if c <= m || atomic.CompareAndSwapInt32(&maxConcurrent, m, c) {
				break
			}
		}
		time.Sleep(5 * time.Millisecond)
		atomic.AddInt32(&concurrent, -1)
		atomic.AddInt32(&runs, 1)
		return nil
	})
	e.Start(ctx)

	for i := 0; i < 50; i++ {
		e.Trigger("burst")
	}
	waitFor(t, func() bool { return atomic.LoadInt32(&runs) >= 1 })
	time.Sleep(100 * time.Millisecond)
	if atomic.LoadInt32(&maxConcurrent) > 1 {
		t.Fatalf("syncs overlapped: maxConcurrent=%d", atomic.LoadInt32(&maxConcurrent))
	}
}

func TestSyncEngineCoalesces(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var runs int32
	release := make(chan struct{})
	first := make(chan struct{}, 1)
	e := NewSyncEngine(func(ctx context.Context, reason string) error {
		n := atomic.AddInt32(&runs, 1)
		if n == 1 {
			first <- struct{}{}
			<-release // hold the first run open while we fire many triggers
		}
		return nil
	})
	e.Start(ctx)

	e.Trigger("t0")
	<-first // first run is now in-flight
	for i := 0; i < 20; i++ {
		e.Trigger("tN") // all coalesce into ONE follow-up
	}
	close(release)

	// Exactly one coalesced follow-up run (total 2), not 21.
	waitFor(t, func() bool { return atomic.LoadInt32(&runs) >= 2 })
	time.Sleep(50 * time.Millisecond)
	if got := atomic.LoadInt32(&runs); got != 2 {
		t.Fatalf("expected 2 runs (1 + 1 coalesced), got %d", got)
	}
	if e.PendingCount() < 21 {
		t.Fatalf("pendingCount should count every trigger, got %d", e.PendingCount())
	}
}

func TestSyncEngineRetriesOnLock(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var attempts int32
	var retries int32
	e := NewSyncEngine(func(ctx context.Context, reason string) error {
		if atomic.AddInt32(&attempts, 1) < 3 {
			return errors.New("database is locked")
		}
		return nil
	})
	e.lockBackoff = time.Millisecond
	e.onLockRetry = func() { atomic.AddInt32(&retries, 1) }
	e.Start(ctx)

	e.Trigger("locked")
	waitFor(t, func() bool { return atomic.LoadInt32(&attempts) >= 3 })
	if atomic.LoadInt32(&retries) < 2 {
		t.Fatalf("expected >=2 lock retries, got %d", atomic.LoadInt32(&retries))
	}
}

func TestSyncEngineBurst(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var mu sync.Mutex
	reasons := map[string]int{}
	e := NewSyncEngine(func(ctx context.Context, reason string) error {
		mu.Lock()
		reasons[reason]++
		mu.Unlock()
		return nil
	})
	e.Start(ctx)
	e.TriggerBurst(ctx, "send_burst", 3, time.Millisecond)
	waitFor(t, func() bool {
		mu.Lock()
		defer mu.Unlock()
		return reasons["send_burst"] >= 1
	})
}

func TestSyncEngineTriggerBurstCancelsPreviousAndExitsOnContextCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var mu sync.Mutex
	reasons := map[string]int{}
	e := NewSyncEngine(func(ctx context.Context, reason string) error {
		mu.Lock()
		reasons[reason]++
		mu.Unlock()
		return nil
	})
	e.Start(ctx)

	// Start a long burst, then immediately replace it with a newer burst.
	e.TriggerBurst(ctx, "old_burst", 20, 20*time.Millisecond)
	e.TriggerBurst(ctx, "new_burst", 3, 5*time.Millisecond)

	waitFor(t, func() bool {
		mu.Lock()
		defer mu.Unlock()
		return reasons["new_burst"] >= 1
	})
	time.Sleep(60 * time.Millisecond)

	mu.Lock()
	oldCountAfterReplace := reasons["old_burst"]
	mu.Unlock()
	if oldCountAfterReplace > 1 {
		t.Fatalf("old burst was not cancelled on replacement: old_burst ran %d times", oldCountAfterReplace)
	}

	// Start another long burst and cancel parent ctx; triggers must stop promptly.
	burstCtx, burstCancel := context.WithCancel(ctx)
	e.TriggerBurst(burstCtx, "cancel_burst", 50, 10*time.Millisecond)
	burstCancel()
	time.Sleep(50 * time.Millisecond)

	mu.Lock()
	afterCancel1 := reasons["cancel_burst"]
	mu.Unlock()
	time.Sleep(40 * time.Millisecond)
	mu.Lock()
	afterCancel2 := reasons["cancel_burst"]
	mu.Unlock()
	if afterCancel2 != afterCancel1 {
		t.Fatalf("burst kept firing after ctx cancel: %d -> %d", afterCancel1, afterCancel2)
	}
}

func TestIsDBLockedError(t *testing.T) {
	if !isDBLockedError(errors.New("database is locked")) {
		t.Fatal("should detect locked")
	}
	if isDBLockedError(errors.New("not found")) {
		t.Fatal("should not detect non-lock")
	}
	if isDBLockedError(nil) {
		t.Fatal("nil is not locked")
	}
}

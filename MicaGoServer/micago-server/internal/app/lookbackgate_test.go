package app

import (
	"testing"
	"time"
)

func TestLookbackGateThrottles(t *testing.T) {
	gate := newLookbackGate(time.Minute)
	t0 := time.Date(2026, 7, 4, 12, 0, 0, 0, time.UTC)

	if !gate.take(t0) {
		t.Fatal("first take must run (startup lookback)")
	}
	if gate.take(t0.Add(5 * time.Second)) {
		t.Fatal("take within the period must be throttled")
	}
	if gate.take(t0.Add(59 * time.Second)) {
		t.Fatal("take just under the period must be throttled")
	}
	if !gate.take(t0.Add(time.Minute)) {
		t.Fatal("take at the period boundary must run")
	}
}

// A failed sync consumed the slot without scanning; rearm must give it back so
// recovery isn't delayed a full period.
func TestLookbackGateRearmAfterFailure(t *testing.T) {
	gate := newLookbackGate(time.Minute)
	t0 := time.Date(2026, 7, 4, 12, 0, 0, 0, time.UTC)

	if !gate.take(t0) {
		t.Fatal("first take must run")
	}
	gate.rearm()
	if !gate.take(t0.Add(time.Second)) {
		t.Fatal("take after rearm must run immediately")
	}
}

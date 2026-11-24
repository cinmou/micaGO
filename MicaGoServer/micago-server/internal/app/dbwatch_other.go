//go:build !darwin

package app

import (
	"context"
	"time"
)

func runDBWatchLoop(
	ctx context.Context,
	dbPath string,
	diagnostics *syncDiagnostics,
	trigger func(string),
) {
	runDBMtimeSyncLoop(ctx, dbPath, 750*time.Millisecond, diagnostics, trigger)
}

package send

import (
	"context"
	"os/exec"
	"runtime"
	"strings"
	"sync"
	"time"
)

// AutomationStatus is the result of probing whether this process may drive
// Messages.app through Apple Events.
type AutomationStatus struct {
	Status string // "ok" | "denied" | "unknown"
	Detail string
}

// C79: Automation used to be hardcoded to "unknown" in Permission Diagnostics
// with a note telling the user to go check System Settings themselves — the one
// permission that actually breaks sending was also the only one the dashboard
// could not answer.
//
// It *can* be probed without sending anything: ask Messages for a harmless
// read-only property. macOS answers with error -1743 ("Not authorized to send
// Apple events") when Automation is denied, and succeeds when it is granted.
// The probe is gated on Messages already running (an AppleScript `tell` would
// otherwise launch it) and reuses the same pgrep check as the send path.
//
// The result is cached: the dashboard polls every few seconds and each probe
// spawns osascript.
const (
	automationProbeTTL     = 60 * time.Second
	automationProbeTimeout = 5 * time.Second
	// macOS returns this OSStatus when the user has denied Automation for the
	// requesting app, and this text alongside it.
	automationDeniedCode = "-1743"
	automationDeniedText = "not authorized to send apple events"
)

var (
	automationMu       sync.Mutex
	automationCached   AutomationStatus
	automationCachedAt time.Time
)

// ProbeAutomation reports whether AppleScript control of Messages is permitted.
// Never mutates anything: it reads a single property.
func ProbeAutomation(ctx context.Context) AutomationStatus {
	automationMu.Lock()
	if !automationCachedAt.IsZero() && time.Since(automationCachedAt) < automationProbeTTL {
		cached := automationCached
		automationMu.Unlock()
		return cached
	}
	automationMu.Unlock()

	status := probeAutomationUncached(ctx)

	automationMu.Lock()
	automationCached = status
	automationCachedAt = time.Now()
	automationMu.Unlock()
	return status
}

func probeAutomationUncached(ctx context.Context) AutomationStatus {
	if runtime.GOOS != "darwin" {
		return AutomationStatus{
			Status: "unknown",
			Detail: "Automation applies to macOS only",
		}
	}
	// An AppleScript `tell` launches the target app, so only probe when Messages
	// is already open — otherwise this diagnostic would start Messages by itself.
	running, err := MessagesRunning(ctx)
	if err == nil && !running {
		return AutomationStatus{
			Status: "unknown",
			Detail: "open Messages to check Automation access",
		}
	}

	probeCtx, cancel := context.WithTimeout(ctx, automationProbeTimeout)
	defer cancel()
	// Reading `name` needs the same Automation permission as sending, but
	// changes nothing.
	out, err := exec.CommandContext(
		probeCtx,
		"osascript",
		"-e",
		`tell application "Messages" to get name`,
	).CombinedOutput()
	if err == nil {
		return AutomationStatus{
			Status: "ok",
			Detail: "AppleScript control of Messages is allowed",
		}
	}

	message := strings.ToLower(strings.TrimSpace(string(out)))
	if strings.Contains(message, automationDeniedCode) ||
		strings.Contains(message, automationDeniedText) {
		return AutomationStatus{
			Status: "denied",
			Detail: "allow control of Messages in System Settings > Privacy & Security > Automation, then re-check",
		}
	}
	detail := strings.TrimSpace(string(out))
	if detail == "" {
		detail = err.Error()
	}
	return AutomationStatus{
		Status: "unknown",
		Detail: "could not determine Automation access: " + detail,
	}
}

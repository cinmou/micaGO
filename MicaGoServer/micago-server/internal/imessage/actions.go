package imessage

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type Action string

const (
	ActionEdit    Action = "edit"
	ActionRetract Action = "retract"
	ActionDelete  Action = "delete"
)

// Helper lifecycle states surfaced to the UI so it can show exactly where the
// IMCore helper is: not present, present but won't run, runs but lacks the
// required selectors, or fully usable.
const (
	HelperStateMissing     = "missing"               // no helper binary found
	HelperStateNotRunnable = "not_runnable"          // found, but it failed to run
	HelperStateUnsupported = "unsupported_selectors" // ran, but no usable actions
	HelperStateReady       = "ready"                 // usable
)

type Capabilities struct {
	Edit              bool   `json:"edit"`
	Retract           bool   `json:"retract"`
	Delete            bool   `json:"delete"`
	Available         bool   `json:"available"`
	State             string `json:"state"`
	Helper            string `json:"helper,omitempty"`
	Reason            string `json:"reason,omitempty"`
	RequiresMessages  bool   `json:"requiresMessages"`
	MinimumMacOS      string `json:"minimumMacOS,omitempty"`
	PlatformSupported bool   `json:"platformSupported"`
	PlatformWarning   string `json:"platformWarning,omitempty"`
}

type Request struct {
	Action      Action `json:"action"`
	ChatGUID    string `json:"chatGuid"`
	MessageGUID string `json:"messageGuid"`
	Text        string `json:"text,omitempty"`
	PartIndex   int    `json:"partIndex"`
}

type ActionError struct {
	Code       string
	Message    string
	Retryable  bool
	StatusCode int
}

func (e *ActionError) Error() string { return e.Message }

func ErrorCode(err error) string {
	var actionErr *ActionError
	if errors.As(err, &actionErr) {
		return actionErr.Code
	}
	return "action_failed"
}

func ErrorStatus(err error) int {
	var actionErr *ActionError
	if errors.As(err, &actionErr) && actionErr.StatusCode != 0 {
		return actionErr.StatusCode
	}
	return 500
}

type Performer interface {
	Capabilities(ctx context.Context) Capabilities
	Edit(ctx context.Context, req Request) error
	Retract(ctx context.Context, req Request) error
	Delete(ctx context.Context, req Request) error
}

type HelperPerformer struct {
	Path    string
	Lookup  func() (string, error)
	Runner  func(context.Context, string, helperEnvelope) (helperEnvelope, error)
	Timeout time.Duration
	// CacheTTL caches the capability probe result so frequent status polls (the
	// companion polls every few seconds) don't spawn the helper subprocess each
	// time. Zero disables caching (used by tests for deterministic behavior).
	CacheTTL time.Duration

	capMu     sync.Mutex
	cachedCap *Capabilities
	cachedAt  time.Time
}

type helperEnvelope struct {
	Action       string          `json:"action"`
	ChatGUID     string          `json:"chatGuid,omitempty"`
	MessageGUID  string          `json:"messageGuid,omitempty"`
	Text         string          `json:"text,omitempty"`
	PartIndex    int             `json:"partIndex,omitempty"`
	OK           bool            `json:"ok,omitempty"`
	Error        string          `json:"error,omitempty"`
	Code         string          `json:"code,omitempty"`
	Capabilities map[string]bool `json:"capabilities,omitempty"`
}

func NewHelperPerformer(path string) *HelperPerformer {
	return &HelperPerformer{Path: strings.TrimSpace(path), Timeout: 12 * time.Second, CacheTTL: 30 * time.Second}
}

func (p *HelperPerformer) Capabilities(ctx context.Context) Capabilities {
	if p.CacheTTL > 0 {
		p.capMu.Lock()
		if p.cachedCap != nil && time.Since(p.cachedAt) < p.CacheTTL {
			c := *p.cachedCap
			p.capMu.Unlock()
			return c
		}
		p.capMu.Unlock()
	}
	c := p.probeCapabilities(ctx)
	if p.CacheTTL > 0 {
		p.capMu.Lock()
		p.cachedCap = &c
		p.cachedAt = time.Now()
		p.capMu.Unlock()
	}
	return c
}

// InvalidateCapabilities drops the cached probe result so the next
// Capabilities() call re-scans the disk + re-runs the helper. Called right after
// a helper install so a freshly-installed helper is reported immediately rather
// than after the cache TTL expires.
func (p *HelperPerformer) InvalidateCapabilities() {
	p.capMu.Lock()
	p.cachedCap = nil
	p.cachedAt = time.Time{}
	p.capMu.Unlock()
}

func (p *HelperPerformer) probeCapabilities(ctx context.Context) Capabilities {
	platform := ActionPlatformSupport()
	if !platform.Supported {
		return platform.apply(Capabilities{
			Available:        false,
			State:            HelperStateUnsupported,
			Reason:           platform.Reason,
			RequiresMessages: true,
		})
	}
	path, err := p.helperPath()
	if err != nil {
		// No usable path. Distinguish "nothing installed" from "found but not
		// executable" so the UI can tell the user what to do.
		state := HelperStateMissing
		if strings.Contains(strings.ToLower(err.Error()), "not executable") {
			state = HelperStateNotRunnable
		}
		return platform.apply(Capabilities{
			Available:        false,
			State:            state,
			Reason:           err.Error(),
			RequiresMessages: true,
		})
	}
	env, err := p.run(ctx, path, helperEnvelope{Action: "status"})
	if err != nil {
		return platform.apply(Capabilities{
			Available:        false,
			State:            HelperStateNotRunnable,
			Helper:           path,
			Reason:           err.Error(),
			RequiresMessages: true,
		})
	}
	caps := env.Capabilities
	edit, retract, del := caps["edit"], caps["retract"], caps["delete"]
	if !edit && !retract && !del {
		// The helper ran but reports none of the required selectors (e.g. a macOS
		// where the private IMCore API changed). Not usable.
		return platform.apply(Capabilities{
			Available:        false,
			State:            HelperStateUnsupported,
			Helper:           path,
			Reason:           "the IMCore helper ran but none of edit/unsend/delete are supported on this macOS",
			RequiresMessages: true,
		})
	}
	return platform.apply(Capabilities{
		Available:        true,
		State:            HelperStateReady,
		Helper:           path,
		Edit:             edit,
		Retract:          retract,
		Delete:           del,
		RequiresMessages: true,
	})
}

func (p *HelperPerformer) Edit(ctx context.Context, req Request) error {
	if strings.TrimSpace(req.Text) == "" {
		return &ActionError{Code: "bad_request", Message: "edited text is required", StatusCode: 400}
	}
	return p.perform(ctx, Request{Action: ActionEdit, ChatGUID: req.ChatGUID, MessageGUID: req.MessageGUID, Text: req.Text, PartIndex: req.PartIndex})
}

func (p *HelperPerformer) Retract(ctx context.Context, req Request) error {
	return p.perform(ctx, Request{Action: ActionRetract, ChatGUID: req.ChatGUID, MessageGUID: req.MessageGUID, PartIndex: req.PartIndex})
}

func (p *HelperPerformer) Delete(ctx context.Context, req Request) error {
	return p.perform(ctx, Request{Action: ActionDelete, ChatGUID: req.ChatGUID, MessageGUID: req.MessageGUID})
}

func (p *HelperPerformer) perform(ctx context.Context, req Request) error {
	if strings.TrimSpace(req.ChatGUID) == "" {
		return &ActionError{Code: "bad_request", Message: "chatGuid is required", StatusCode: 400}
	}
	if strings.TrimSpace(req.MessageGUID) == "" {
		return &ActionError{Code: "bad_request", Message: "messageGuid is required", StatusCode: 400}
	}
	path, err := p.helperPath()
	if err != nil {
		return &ActionError{Code: "unsupported", Message: err.Error(), StatusCode: 501}
	}
	env := helperEnvelope{
		Action:      string(req.Action),
		ChatGUID:    req.ChatGUID,
		MessageGUID: req.MessageGUID,
		Text:        req.Text,
		PartIndex:   req.PartIndex,
	}
	resp, err := p.run(ctx, path, env)
	if err != nil {
		return mapHelperError(err.Error())
	}
	if resp.OK {
		return nil
	}
	if resp.Code == "" {
		resp.Code = "action_failed"
	}
	if resp.Error == "" {
		resp.Error = "iMessage action failed"
	}
	return mapHelperErrorCode(resp.Code, resp.Error)
}

func (p *HelperPerformer) helperPath() (string, error) {
	if p.Lookup != nil {
		return p.Lookup()
	}
	if p.Path != "" {
		if isExecutable(p.Path) {
			return p.Path, nil
		}
		return "", fmt.Errorf("MicaGo IMCore helper is not executable: %s", p.Path)
	}
	if env := strings.TrimSpace(os.Getenv("MICAGO_IMCORE_HELPER")); env != "" {
		if isExecutable(env) {
			return env, nil
		}
		return "", fmt.Errorf("MICAGO_IMCORE_HELPER is not executable: %s", env)
	}
	exe, err := os.Executable()
	if err == nil {
		dir := filepath.Dir(exe)
		for _, name := range []string{"micago-imcore-helper", "MicaGoIMCoreHelper"} {
			candidate := filepath.Join(dir, name)
			if isExecutable(candidate) {
				return candidate, nil
			}
		}
		if strings.Contains(dir, ".app/Contents/MacOS") {
			resources := filepath.Clean(filepath.Join(dir, "..", "Resources"))
			for _, name := range []string{"micago-imcore-helper", "MicaGoIMCoreHelper"} {
				candidate := filepath.Join(resources, name)
				if isExecutable(candidate) {
					return candidate, nil
				}
			}
		}
	}
	// C26: the stable install location the Companion's "Install" action targets,
	// so a helper MicaGo installs is picked up without re-bundling the backend.
	if home, err := os.UserHomeDir(); err == nil {
		for _, name := range []string{"micago-imcore-helper", "MicaGoIMCoreHelper"} {
			candidate := filepath.Join(home, ".micago", "bin", name)
			if isExecutable(candidate) {
				return candidate, nil
			}
		}
	}
	return "", errors.New("MicaGo IMCore helper is not installed")
}

func (p *HelperPerformer) run(ctx context.Context, path string, env helperEnvelope) (helperEnvelope, error) {
	if p.Runner != nil {
		return p.Runner(ctx, path, env)
	}
	timeout := p.Timeout
	if timeout <= 0 {
		timeout = 12 * time.Second
	}
	runCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	body, err := json.Marshal(env)
	if err != nil {
		return helperEnvelope{}, err
	}
	cmd := exec.CommandContext(runCtx, path)
	cmd.Stdin = bytes.NewReader(body)
	var out, stderr bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return helperEnvelope{}, errors.New(msg)
	}
	var resp helperEnvelope
	if err := json.Unmarshal(out.Bytes(), &resp); err != nil {
		return helperEnvelope{}, fmt.Errorf("decode helper response: %w", err)
	}
	return resp, nil
}

func isExecutable(path string) bool {
	info, err := os.Stat(path)
	if err != nil || info.IsDir() {
		return false
	}
	return info.Mode()&0o111 != 0
}

func mapHelperError(msg string) error {
	lower := strings.ToLower(msg)
	switch {
	case strings.Contains(lower, "not available"), strings.Contains(lower, "selector"), strings.Contains(lower, "not supported"):
		return mapHelperErrorCode("unsupported", msg)
	case strings.Contains(lower, "expired"), strings.Contains(lower, "too old"):
		return mapHelperErrorCode("expired", msg)
	case strings.Contains(lower, "not allowed"), strings.Contains(lower, "permission"):
		return mapHelperErrorCode("not_allowed", msg)
	case strings.Contains(lower, "not found"):
		return mapHelperErrorCode("not_found", msg)
	default:
		return mapHelperErrorCode("action_failed", msg)
	}
}

func mapHelperErrorCode(code, msg string) error {
	status := 500
	switch code {
	case "bad_request":
		status = 400
	case "not_allowed", "expired":
		status = 409
	case "not_found":
		status = 404
	case "unsupported":
		status = 501
	}
	return &ActionError{Code: code, Message: msg, StatusCode: status}
}

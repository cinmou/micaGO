package relaydb

import (
	"context"
	"fmt"
	"strings"
	"time"

	"micagoserver/internal/store"
)

// Sync-rule constants (v0.11.3). See docs/features/messaging.md.
const (
	TargetChat   = "chat"
	TargetHandle = "handle"

	SyncAllow   = "allow"
	SyncBlock   = "block"
	SyncInherit = "inherit"

	PushEnabled = "enabled"
	PushMuted   = "muted"
	PushInherit = "inherit"

	PolicyAllowAll = "allow_all"
	PolicyBlockAll = "block_all"
	PolicyEnabled  = "enabled"
	PolicyMuted    = "muted"

	keyDefaultSyncPolicy = "sync_default_policy"
	keyDefaultPushPolicy = "push_default_policy"
)

// NormalizeHandle canonicalizes a phone/email handle so rule targets match
// message handles consistently. Emails are lowercased; phone-like values keep a
// leading "+" and digits only.
func NormalizeHandle(raw string) string {
	s := strings.TrimSpace(raw)
	if s == "" {
		return ""
	}
	if strings.Contains(s, "@") {
		return strings.ToLower(s)
	}
	var b strings.Builder
	for i, r := range s {
		if r >= '0' && r <= '9' {
			b.WriteRune(r)
		} else if r == '+' && i == 0 {
			b.WriteRune(r)
		}
	}
	out := b.String()
	if out == "" {
		return strings.ToLower(s) // fall back to a lowercased raw value
	}
	return out
}

type ruleModes struct {
	sync string
	push string
}

// RuleSnapshot is an in-memory view of the rules + default policy, evaluated per
// message during a sync tick.
type RuleSnapshot struct {
	hidden              map[string]bool
	defaultSyncAllowAll bool
	defaultPushEnabled  bool
	chat                map[string]ruleModes
	handle              map[string]ruleModes
}

// SyncAllowed applies chat > handle > default precedence to the sync decision.
func (s RuleSnapshot) SyncAllowed(chatGUID string, handle *string) bool {
	if m, ok := s.chat[chatGUID]; ok && m.sync != SyncInherit {
		return m.sync == SyncAllow
	}
	if h := normalizeHandlePtr(handle); h != "" {
		if m, ok := s.handle[h]; ok && m.sync != SyncInherit {
			return m.sync == SyncAllow
		}
	}
	return s.defaultSyncAllowAll
}

// PushEnabled gates push on the sync decision, then applies chat > handle >
// default precedence to the push decision. A non-synced message never pushes.
func (s RuleSnapshot) PushEnabled(chatGUID string, handle *string) bool {
	if s.hidden[chatGUID] {
		return false
	}
	if !s.SyncAllowed(chatGUID, handle) {
		return false
	}
	if m, ok := s.chat[chatGUID]; ok && m.push != PushInherit {
		return m.push == PushEnabled
	}
	if h := normalizeHandlePtr(handle); h != "" {
		if m, ok := s.handle[h]; ok && m.push != PushInherit {
			return m.push == PushEnabled
		}
	}
	return s.defaultPushEnabled
}

func normalizeHandlePtr(handle *string) string {
	if handle == nil {
		return ""
	}
	return NormalizeHandle(*handle)
}

// LoadRuleSnapshot reads the default policy + all rules into an in-memory
// snapshot for use during a sync tick.
func (db *DB) LoadRuleSnapshot(ctx context.Context) (RuleSnapshot, error) {
	syncPolicy, pushPolicy, err := db.DefaultPolicies(ctx)
	if err != nil {
		return RuleSnapshot{}, err
	}
	snap := RuleSnapshot{
		hidden:              map[string]bool{},
		defaultSyncAllowAll: syncPolicy != PolicyBlockAll,
		defaultPushEnabled:  pushPolicy != PolicyMuted,
		chat:                map[string]ruleModes{},
		handle:              map[string]ruleModes{},
	}

	hiddenRows, err := db.sqlDB.QueryContext(ctx, "SELECT chat_guid FROM chat_preferences WHERE hidden=1")
	if err != nil {
		return RuleSnapshot{}, err
	}
	for hiddenRows.Next() {
		var guid string
		if err := hiddenRows.Scan(&guid); err != nil {
			hiddenRows.Close()
			return RuleSnapshot{}, err
		}
		snap.hidden[guid] = true
	}
	if err := hiddenRows.Err(); err != nil {
		hiddenRows.Close()
		return RuleSnapshot{}, err
	}
	hiddenRows.Close()
	rows, err := db.sqlDB.QueryContext(ctx, `SELECT target_kind, target_value, sync_mode, push_mode FROM sync_rules`)
	if err != nil {
		return RuleSnapshot{}, err
	}
	defer rows.Close()
	for rows.Next() {
		var kind, value, syncMode, pushMode string
		if err := rows.Scan(&kind, &value, &syncMode, &pushMode); err != nil {
			return RuleSnapshot{}, err
		}
		modes := ruleModes{sync: syncMode, push: pushMode}
		switch kind {
		case TargetChat:
			snap.chat[value] = modes
		case TargetHandle:
			snap.handle[NormalizeHandle(value)] = modes
		}
	}
	if err := rows.Err(); err != nil {
		return RuleSnapshot{}, err
	}
	return snap, nil
}

// DefaultPolicies returns the stored default sync/push policy (with defaults).
func (db *DB) DefaultPolicies(_ context.Context) (syncPolicy string, pushPolicy string, err error) {
	syncPolicy = PolicyAllowAll
	pushPolicy = PolicyEnabled
	if v, ok, e := db.GetSyncState(keyDefaultSyncPolicy); e != nil {
		return "", "", e
	} else if ok && strings.TrimSpace(v) != "" {
		syncPolicy = v
	}
	if v, ok, e := db.GetSyncState(keyDefaultPushPolicy); e != nil {
		return "", "", e
	} else if ok && strings.TrimSpace(v) != "" {
		pushPolicy = v
	}
	return syncPolicy, pushPolicy, nil
}

// SetDefaultPolicies persists the default sync/push policy.
func (db *DB) SetDefaultPolicies(_ context.Context, syncPolicy, pushPolicy string) error {
	if syncPolicy != PolicyAllowAll && syncPolicy != PolicyBlockAll {
		return fmt.Errorf("invalid default sync policy %q", syncPolicy)
	}
	if pushPolicy != PolicyEnabled && pushPolicy != PolicyMuted {
		return fmt.Errorf("invalid default push policy %q", pushPolicy)
	}
	if err := db.SetSyncState(keyDefaultSyncPolicy, syncPolicy); err != nil {
		return err
	}
	return db.SetSyncState(keyDefaultPushPolicy, pushPolicy)
}

// ListSyncRules returns all rules ordered by kind then value.
func (db *DB) ListSyncRules(ctx context.Context) ([]store.SyncRuleJSON, error) {
	rows, err := db.sqlDB.QueryContext(ctx, `
SELECT target_kind, target_value, sync_mode, push_mode, created_at, updated_at
FROM sync_rules ORDER BY target_kind, target_value`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]store.SyncRuleJSON, 0)
	for rows.Next() {
		var r store.SyncRuleJSON
		if err := rows.Scan(&r.TargetKind, &r.TargetValue, &r.SyncMode, &r.PushMode, &r.CreatedAt, &r.UpdatedAt); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// UpsertSyncRule creates or updates a rule for a target (handle values are
// normalized). An inherit/inherit rule is allowed (a no-op override placeholder).
func (db *DB) UpsertSyncRule(ctx context.Context, rule store.SyncRuleJSON) error {
	if rule.TargetKind != TargetChat && rule.TargetKind != TargetHandle {
		return fmt.Errorf("invalid target kind %q", rule.TargetKind)
	}
	if !validSyncMode(rule.SyncMode) {
		return fmt.Errorf("invalid sync mode %q", rule.SyncMode)
	}
	if !validPushMode(rule.PushMode) {
		return fmt.Errorf("invalid push mode %q", rule.PushMode)
	}
	value := strings.TrimSpace(rule.TargetValue)
	if value == "" {
		return fmt.Errorf("target value is required")
	}
	if rule.TargetKind == TargetHandle {
		value = NormalizeHandle(value)
	}

	now := time.Now().UnixMilli()
	_, err := db.sqlDB.ExecContext(ctx, `
INSERT INTO sync_rules (target_kind, target_value, sync_mode, push_mode, created_at, updated_at)
VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT(target_kind, target_value) DO UPDATE SET
	sync_mode = excluded.sync_mode,
	push_mode = excluded.push_mode,
	updated_at = excluded.updated_at;
`, rule.TargetKind, value, rule.SyncMode, rule.PushMode, now, now)
	return err
}

// DeleteSyncRule removes a rule for a target (reverting it to inherit).
func (db *DB) DeleteSyncRule(ctx context.Context, kind, value string) error {
	if kind != TargetChat && kind != TargetHandle {
		return fmt.Errorf("invalid target kind %q", kind)
	}
	v := strings.TrimSpace(value)
	if kind == TargetHandle {
		v = NormalizeHandle(v)
	}
	_, err := db.sqlDB.ExecContext(ctx, `DELETE FROM sync_rules WHERE target_kind = ? AND target_value = ?`, kind, v)
	return err
}

func validSyncMode(m string) bool {
	return m == SyncAllow || m == SyncBlock || m == SyncInherit
}

func validPushMode(m string) bool {
	return m == PushEnabled || m == PushMuted || m == PushInherit
}

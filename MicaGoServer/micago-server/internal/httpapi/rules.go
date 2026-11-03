package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"

	"micagoserver/internal/realtime"
	"micagoserver/internal/store"
)

// ruleService is the v0.11.3 sync-rule store (implemented by relaydb.DB).
type ruleService interface {
	ListSyncRules(ctx context.Context) ([]store.SyncRuleJSON, error)
	UpsertSyncRule(ctx context.Context, rule store.SyncRuleJSON) error
	DeleteSyncRule(ctx context.Context, kind, value string) error
	DefaultPolicies(ctx context.Context) (syncPolicy string, pushPolicy string, err error)
	SetDefaultPolicies(ctx context.Context, syncPolicy, pushPolicy string) error
}

const (
	targetChat   = "chat"
	targetHandle = "handle"
)

func validTargetKind(k string) bool { return k == targetChat || k == targetHandle }
func validSyncMode(m string) bool   { return m == "allow" || m == "block" || m == "inherit" }
func validPushMode(m string) bool   { return m == "enabled" || m == "muted" || m == "inherit" }
func validSyncPolicy(p string) bool { return p == "allow_all" || p == "block_all" }
func validPushPolicy(p string) bool { return p == "enabled" || p == "muted" }

// GET /api/sync/rules
func (h *Handlers) GetSyncRules(w http.ResponseWriter, r *http.Request) {
	if h.rules == nil {
		writeInternalError(w)
		return
	}
	resp, err := h.buildSyncRulesResponse(r.Context())
	if err != nil {
		h.logInternal("list sync rules", err)
		writeInternalError(w)
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

// PUT /api/sync/rules — upsert a rule for a target.
func (h *Handlers) PutSyncRule(w http.ResponseWriter, r *http.Request) {
	if h.rules == nil {
		writeInternalError(w)
		return
	}
	var req store.SyncRuleJSON
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeBadRequest(w, "invalid JSON body")
		return
	}
	req.TargetKind = strings.TrimSpace(req.TargetKind)
	req.TargetValue = strings.TrimSpace(req.TargetValue)
	if req.SyncMode == "" {
		req.SyncMode = "inherit"
	}
	if req.PushMode == "" {
		req.PushMode = "inherit"
	}
	if !validTargetKind(req.TargetKind) {
		writeBadRequest(w, "targetKind must be one of: chat, handle")
		return
	}
	if req.TargetValue == "" {
		writeBadRequest(w, "targetValue is required")
		return
	}
	if !validSyncMode(req.SyncMode) {
		writeBadRequest(w, "syncMode must be one of: allow, block, inherit")
		return
	}
	if !validPushMode(req.PushMode) {
		writeBadRequest(w, "pushMode must be one of: enabled, muted, inherit")
		return
	}

	if err := h.rules.UpsertSyncRule(r.Context(), req); err != nil {
		h.logInternal("upsert sync rule", err)
		writeInternalError(w)
		return
	}
	h.respondSyncRules(w, r)
}

// DELETE /api/sync/rules/{kind}/{value}
func (h *Handlers) DeleteSyncRule(w http.ResponseWriter, r *http.Request) {
	if h.rules == nil {
		writeInternalError(w)
		return
	}
	kind := strings.TrimSpace(r.PathValue("kind"))
	value := strings.TrimSpace(r.PathValue("value"))
	if !validTargetKind(kind) {
		writeBadRequest(w, "targetKind must be one of: chat, handle")
		return
	}
	if value == "" {
		writeBadRequest(w, "target value is required")
		return
	}
	if err := h.rules.DeleteSyncRule(r.Context(), kind, value); err != nil {
		h.logInternal("delete sync rule", err)
		writeInternalError(w)
		return
	}
	h.respondSyncRules(w, r)
}

// PUT /api/sync/policy — set the default sync/push policy.
func (h *Handlers) PutSyncPolicy(w http.ResponseWriter, r *http.Request) {
	if h.rules == nil {
		writeInternalError(w)
		return
	}
	var req struct {
		DefaultSyncPolicy string `json:"defaultSyncPolicy"`
		DefaultPushPolicy string `json:"defaultPushPolicy"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeBadRequest(w, "invalid JSON body")
		return
	}
	if !validSyncPolicy(req.DefaultSyncPolicy) {
		writeBadRequest(w, "defaultSyncPolicy must be one of: allow_all, block_all")
		return
	}
	if !validPushPolicy(req.DefaultPushPolicy) {
		writeBadRequest(w, "defaultPushPolicy must be one of: enabled, muted")
		return
	}
	if err := h.rules.SetDefaultPolicies(r.Context(), req.DefaultSyncPolicy, req.DefaultPushPolicy); err != nil {
		h.logInternal("set default policy", err)
		writeInternalError(w)
		return
	}
	h.respondSyncRules(w, r)
}

func (h *Handlers) respondSyncRules(w http.ResponseWriter, r *http.Request) {
	resp, err := h.buildSyncRulesResponse(r.Context())
	if err != nil {
		h.logInternal("build sync rules response", err)
		writeInternalError(w)
		return
	}
	if h.send != nil && h.send.Events != nil {
		_ = h.send.Events.Broadcast(context.WithoutCancel(r.Context()), realtime.Event{Type: "sync:rules", Data: resp})
	}
	writeJSON(w, http.StatusOK, resp)
}

func (h *Handlers) buildSyncRulesResponse(ctx context.Context) (store.SyncRulesResponse, error) {
	syncPolicy, pushPolicy, err := h.rules.DefaultPolicies(ctx)
	if err != nil {
		return store.SyncRulesResponse{}, err
	}
	rules, err := h.rules.ListSyncRules(ctx)
	if err != nil {
		return store.SyncRulesResponse{}, err
	}
	return store.SyncRulesResponse{
		DefaultSyncPolicy: syncPolicy,
		DefaultPushPolicy: pushPolicy,
		Rules:             rules,
	}, nil
}

// PutChatsMuted is deliberately narrower than administrator rule editing.
func (h *Handlers) PutChatsMuted(w http.ResponseWriter, r *http.Request) {
	svc, ok := h.rules.(interface {
		SetChatsMuted(context.Context, []string, bool) error
	})
	if !ok {
		writeInternalError(w)
		return
	}
	var req struct {
		ChatGUIDs []string `json:"chatGuids"`
		Muted     *bool    `json:"muted"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&req); err != nil || req.Muted == nil || len(req.ChatGUIDs) == 0 || len(req.ChatGUIDs) > 100 {
		writeBadRequest(w, "chatGuids and muted are required (maximum 100 chats)")
		return
	}
	for _, guid := range req.ChatGUIDs {
		if strings.TrimSpace(guid) == "" {
			writeBadRequest(w, "chat GUID is required")
			return
		}
	}
	if err := svc.SetChatsMuted(r.Context(), req.ChatGUIDs, *req.Muted); err != nil {
		h.logInternal("set chat mute", err)
		writeInternalError(w)
		return
	}
	h.respondSyncRules(w, r)
}

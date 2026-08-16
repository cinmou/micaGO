package httpapi

import (
	"encoding/base64"
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"micagoserver/internal/store"
)

const maxMergedHistoryRoutes = 32

func (h *Handlers) GetMergedMessageHistory(w http.ResponseWriter, r *http.Request) {
	limit := defaultLimit
	if raw := r.URL.Query().Get("limit"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 1 || parsed > maxLimit {
			writeBadRequest(w, fmt.Sprintf("limit must be between 1 and %d", maxLimit))
			return
		}
		limit = parsed
	}

	routes := uniqueNonEmpty(r.URL.Query()["chatGuid"])
	if len(routes) == 0 || len(routes) > maxMergedHistoryRoutes {
		writeBadRequest(w, fmt.Sprintf("chatGuid must contain between 1 and %d routes", maxMergedHistoryRoutes))
		return
	}
	for _, guid := range routes {
		exists, err := h.queries.ChatExists(r.Context(), guid)
		if err != nil {
			h.logInternal("check merged history chat exists", err)
			writeInternalError(w)
			return
		}
		if !exists {
			writeNotFound(w, "chat not found")
			return
		}
	}

	beforeDate, beforeRowID, err := decodeHistoryCursor(r.URL.Query().Get("before"))
	if err != nil {
		writeBadRequest(w, "invalid history cursor")
		return
	}
	data, err := h.queries.ListMergedMessages(r.Context(), routes, limit+1, beforeDate, beforeRowID, false)
	if err != nil {
		h.logInternal("list merged message history", err)
		writeInternalError(w)
		return
	}
	hasMore := len(data) > limit
	if hasMore {
		data = data[:limit]
	}
	next := ""
	if hasMore && len(data) > 0 {
		last := data[len(data)-1]
		next = encodeHistoryCursor(valueOrZero(last.DateCreated), valueOrZero(last.SourceRowID))
	}
	writeJSON(w, http.StatusOK, store.MessageHistoryResponse{Data: data, NextCursor: next, HasMore: hasMore})
}

func uniqueNonEmpty(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	result := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if _, exists := seen[value]; exists {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	return result
}

func encodeHistoryCursor(date, rowID int64) string {
	return base64.RawURLEncoding.EncodeToString([]byte(fmt.Sprintf("%d:%d", date, rowID)))
}

func decodeHistoryCursor(cursor string) (*int64, *int64, error) {
	if cursor == "" {
		return nil, nil, nil
	}
	raw, err := base64.RawURLEncoding.DecodeString(cursor)
	if err != nil {
		return nil, nil, err
	}
	parts := strings.Split(string(raw), ":")
	if len(parts) != 2 {
		return nil, nil, fmt.Errorf("invalid cursor")
	}
	date, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil {
		return nil, nil, err
	}
	rowID, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		return nil, nil, err
	}
	return &date, &rowID, nil
}

func valueOrZero(value *int64) int64 {
	if value == nil {
		return 0
	}
	return *value
}

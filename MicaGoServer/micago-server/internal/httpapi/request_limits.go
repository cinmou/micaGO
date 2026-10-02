package httpapi

import "net/http"

const maxJSONRequestBytes int64 = 4 << 20
const maxBatchUploadBytes int64 = 1 << 30
const multipartOverheadBytes int64 = 1 << 20

// Bound the whole upload before multipart parsing can spill data to disk.
func limitRequestBody(w http.ResponseWriter, r *http.Request) bool {
	if r.Body == nil {
		return true
	}
	limit := maxJSONRequestBytes
	switch r.Pattern {
	case "POST /api/chats/{guid}/send-attachment":
		limit = maxOutgoingAttachmentBytes + multipartOverheadBytes
	case "POST /api/chats/{guid}/send-attachments":
		limit = maxBatchUploadBytes + multipartOverheadBytes
	}
	if r.ContentLength > limit {
		writeAPIError(w, http.StatusRequestEntityTooLarge, "request_too_large", "request exceeds the size limit")
		return false
	}
	r.Body = http.MaxBytesReader(w, r.Body, limit)
	return true
}

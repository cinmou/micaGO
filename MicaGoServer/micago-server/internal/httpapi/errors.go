package httpapi

import "net/http"

type errorEnvelope struct {
	Error apiError `json:"error"`
}

type apiError struct {
	Code      string            `json:"code"`
	Message   string            `json:"message"`
	Localized map[string]string `json:"localized,omitempty"`
}

func writeBadRequest(w http.ResponseWriter, message string) {
	writeAPIError(w, http.StatusBadRequest, "bad_request", message)
}

func writeUnauthorized(w http.ResponseWriter) {
	writeAPIError(w, http.StatusUnauthorized, "unauthorized", "unauthorized")
}

func writeNotFound(w http.ResponseWriter, message string) {
	writeAPIError(w, http.StatusNotFound, "not_found", message)
}

func writeInternalError(w http.ResponseWriter) {
	writeAPIError(w, http.StatusInternalServerError, "internal_error", "internal server error")
}

func writeConflict(w http.ResponseWriter, message string) {
	writeAPIError(w, http.StatusConflict, "conflict", message)
}

func writeAPIError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, errorEnvelope{
		Error: apiError{
			Code:      code,
			Message:   message,
			Localized: localizedError(code),
		},
	})
}

func localizedError(code string) map[string]string {
	switch code {
	case "unauthorized":
		return map[string]string{
			"en":      "Unauthorized. Re-pair with the server.",
			"zh-Hans": "未授权。请重新与服务器配对。",
			"zh-Hant": "未授權。請重新與伺服器配對。",
		}
	case "bad_request":
		return map[string]string{
			"en":      "The request was invalid.",
			"zh-Hans": "请求无效。",
			"zh-Hant": "請求無效。",
		}
	case "internal_error":
		return map[string]string{
			"en":      "Internal server error.",
			"zh-Hans": "服务器内部错误。",
			"zh-Hant": "伺服器內部錯誤。",
		}
	case "not_found":
		return map[string]string{
			"en":      "Not found.",
			"zh-Hans": "未找到。",
			"zh-Hant": "找不到。",
		}
	case "unsupported":
		return map[string]string{
			"en":      "This action is not supported on this server or macOS version.",
			"zh-Hans": "此操作不受当前服务器或 macOS 版本支持。",
			"zh-Hant": "此操作不受目前伺服器或 macOS 版本支援。",
		}
	case "push_not_configured":
		return map[string]string{
			"en":      "Push is not configured for this device.",
			"zh-Hans": "此设备尚未配置推送。",
			"zh-Hant": "此裝置尚未設定推播。",
		}
	default:
		return nil
	}
}

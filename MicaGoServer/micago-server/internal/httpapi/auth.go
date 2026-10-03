package httpapi

import (
	"crypto/subtle"
	"log"
	"net/http"
	"strings"
)

type AuthConfig struct {
	Devices *DeviceAuth
	Enabled bool
	Token   string
	Logger  *log.Logger
}

func (c AuthConfig) Wrap(next http.Handler) http.Handler {
	if c.Devices != nil {
		return c.Devices.Wrap(next)
	}
	if !c.Enabled {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if limitRequestBody(w, r) {
				next.ServeHTTP(w, r)
			}
		})
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !validBearerToken(r, c.Token) {
			if c.Logger != nil {
				c.Logger.Printf("auth rejected %s %s from %s: missing or invalid bearer token",
					r.Method, r.URL.Path, r.RemoteAddr)
			}
			writeUnauthorized(w)
			return
		}
		if limitRequestBody(w, r) {
			next.ServeHTTP(w, r)
		}
	})
}

func (c AuthConfig) ValidateRequest(r *http.Request) bool {
	if !c.Enabled {
		return true
	}
	return validBearerToken(r, c.Token)
}

func (c AuthConfig) ValidateWebSocketRequest(r *http.Request) bool {
	if !c.Enabled {
		return true
	}
	if validBearerToken(r, c.Token) {
		return true
	}
	token := strings.TrimSpace(r.URL.Query().Get("token"))
	return constantTimeEqual(token, c.Token)
}

func validBearerToken(r *http.Request, expected string) bool {
	value := strings.TrimSpace(r.Header.Get("Authorization"))
	if value == "" {
		return false
	}
	const prefix = "Bearer "
	if !strings.HasPrefix(value, prefix) {
		return false
	}
	return constantTimeEqual(strings.TrimSpace(strings.TrimPrefix(value, prefix)), expected)
}

func constantTimeEqual(a, b string) bool {
	if b == "" || len(a) != len(b) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

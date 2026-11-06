package httpapi

import (
	"bytes"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"testing"

	"micagoserver/internal/config"
	"micagoserver/internal/store"
)

func newDeviceHandlers() (*Handlers, *stubDeviceStore) {
	ds := &stubDeviceStore{}
	h := NewHandlers(&stubQueries{}, log.New(io.Discard, "", 0), nil, nil, "", ds, stubNotifier{},
		config.Config{HTTPAddr: "127.0.0.1:3000"}, StatusDeps{})
	return h, ds
}

// The exact body the Flutter Android client sends with NO Firebase configured
// (pushProvider "none") must register and then appear in the device list as
// connected — this is the Paired Devices chain.
func TestRegisterAndroidDeviceWithoutFirebaseAppears(t *testing.T) {
	h, _ := newDeviceHandlers()

	body := `{"id":"abc123","name":"MicaGo client","appVersion":"v0.50.0","platform":"android","mode":"lan","clientType":"flutter","pushProvider":"none","pushEnabled":false,"background":false}`
	rec := httptest.NewRecorder()
	h.RegisterDevice(rec, httptest.NewRequest(http.MethodPost, "/api/devices/register", bytes.NewBufferString(body)))
	if rec.Code != http.StatusOK {
		t.Fatalf("register: expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	listRec := httptest.NewRecorder()
	h.ListDevices(listRec, httptest.NewRequest(http.MethodGet, "/api/devices", nil))
	var resp store.DeviceListResponse
	if err := json.Unmarshal(listRec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.Data) != 1 {
		t.Fatalf("expected 1 device, got %d", len(resp.Data))
	}
	d := resp.Data[0]
	if d.Platform != "android" || d.ClientType != "flutter" {
		t.Fatalf("wrong device echoed: %+v", d)
	}
	if !d.Connected {
		t.Fatal("a freshly-registered device must report connected")
	}
}

// Re-registering with the SAME stable id updates the existing row (idempotent),
// never creating a duplicate — a restart must not spawn a second device.
func TestRegisterDeviceIdempotentSameID(t *testing.T) {
	h, ds := newDeviceHandlers()
	post := func(name string) {
		body := `{"id":"stable-1","name":"` + name + `","platform":"android","clientType":"flutter","pushProvider":"none","pushEnabled":false,"background":false}`
		rec := httptest.NewRecorder()
		h.RegisterDevice(rec, httptest.NewRequest(http.MethodPost, "/api/devices/register", bytes.NewBufferString(body)))
		if rec.Code != http.StatusOK {
			t.Fatalf("register %q: got %d: %s", name, rec.Code, rec.Body.String())
		}
	}
	post("First")
	post("Renamed") // same id, second launch
	if len(ds.devices) != 1 {
		t.Fatalf("expected 1 device after re-register, got %d", len(ds.devices))
	}
	if ds.devices["stable-1"].Name != "Renamed" {
		t.Fatalf("re-register did not update the row: %+v", ds.devices["stable-1"])
	}
}

// An FCM device with a token must register too (push-configured path).
func TestRegisterAndroidDeviceWithFcm(t *testing.T) {
	h, _ := newDeviceHandlers()
	body := `{"id":"fcm1","name":"Pixel","platform":"android","clientType":"flutter","pushProvider":"fcm","pushToken":"tok-123","pushEnabled":true,"background":true}`
	rec := httptest.NewRecorder()
	h.RegisterDevice(rec, httptest.NewRequest(http.MethodPost, "/api/devices/register", bytes.NewBufferString(body)))
	if rec.Code != http.StatusOK {
		t.Fatalf("fcm register: expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var resp store.DeviceResponse
	json.Unmarshal(rec.Body.Bytes(), &resp)
	if !resp.Data.PushEnabled || !resp.Data.PushTokenSet || resp.Data.PushProvider != "fcm" {
		t.Fatalf("fcm fields not echoed: %+v", resp.Data)
	}
}

// A UnifiedPush device registers its WebPush subscription as the push token.
// The list echoes only the distributor host, never the capability endpoint.
func TestRegisterAndroidDeviceWithUnifiedPush(t *testing.T) {
	h, _ := newDeviceHandlers()
	token := `{"endpoint":"https://ntfy.example.com/upAbCdEfGhIjKl?up=1","p256dh":"BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4","auth":"BTBZMqHH6r4Tts7J_aSIgg"}`
	tokenJSON, _ := json.Marshal(token)
	body := `{"id":"up1","name":"moto","platform":"android","clientType":"flutter","pushProvider":"unifiedpush","pushToken":` + string(tokenJSON) + `,"pushEnabled":true,"background":true}`
	rec := httptest.NewRecorder()
	h.RegisterDevice(rec, httptest.NewRequest(http.MethodPost, "/api/devices/register", bytes.NewBufferString(body)))
	if rec.Code != http.StatusOK {
		t.Fatalf("unifiedpush register: expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	if bytes.Contains(rec.Body.Bytes(), []byte("upAbCdEfGhIjKl")) {
		t.Fatalf("response leaks the push endpoint: %s", rec.Body.String())
	}
	var resp store.DeviceResponse
	json.Unmarshal(rec.Body.Bytes(), &resp)
	if resp.Data.PushProvider != "unifiedpush" || !resp.Data.PushTokenSet || resp.Data.PushEndpointHost != "ntfy.example.com" {
		t.Fatalf("unifiedpush fields not echoed: %+v", resp.Data)
	}
}

func TestRegisterUnifiedPushRejectsPlainHTTPEndpoint(t *testing.T) {
	h, _ := newDeviceHandlers()
	token := `{"endpoint":"http://192.168.1.10/upAbCdEfGhIjKl","p256dh":"BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4","auth":"BTBZMqHH6r4Tts7J_aSIgg"}`
	tokenJSON, _ := json.Marshal(token)
	body := `{"id":"up2","name":"moto","platform":"android","clientType":"flutter","pushProvider":"unifiedpush","pushToken":` + string(tokenJSON) + `,"pushEnabled":true}`
	rec := httptest.NewRecorder()
	h.RegisterDevice(rec, httptest.NewRequest(http.MethodPost, "/api/devices/register", bytes.NewBufferString(body)))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for http endpoint, got %d: %s", rec.Code, rec.Body.String())
	}
}

// Paired devices (not just the admin token) must be able to fetch the VAPID
// key, otherwise the Android client can never subscribe.
func TestDeviceCredentialMayReadPushConfig(t *testing.T) {
	for _, path := range []string{"/api/fcm/client", "/api/push/unifiedpush"} {
		if !clientRouteAllowed(httptest.NewRequest(http.MethodGet, path, nil), "dev-1") {
			t.Errorf("device credential blocked from GET %s", path)
		}
	}
	if clientRouteAllowed(httptest.NewRequest(http.MethodPost, "/api/server/notifications", nil), "dev-1") {
		t.Error("device credential must not change notification config")
	}
}

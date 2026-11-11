package notify

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"time"

	"micagoserver/internal/store"
)

// UnifiedPush delivery is plain Web Push: RFC 8030 (HTTP request to the
// distributor's endpoint), RFC 8291 (aes128gcm message encryption to the
// device's key) and RFC 8292 (VAPID, required by FCM's WebPush endpoint).
// The push service — ntfy, NextPush, Google — only ever sees ciphertext.

const (
	// webPushRecordSize is the single-record size advertised in the aes128gcm
	// header. Push services cap the whole body at 4096 octets.
	webPushRecordSize = 4096
	webPushMaxBody    = 4096
	// webPushHeaderLen = salt(16) + rs(4) + idlen(1) + uncompressed P-256 key(65).
	webPushHeaderLen = 16 + 4 + 1 + 65
	// webPushOverhead = padding delimiter (1) + AES-GCM tag (16).
	webPushOverhead = 1 + 16
	// webPushMaxBodyChars caps preview text like FCM does; JSON escaping of the
	// remaining fields must still fit in one record.
	webPushMaxBodyChars = 1500
	vapidTokenLifetime  = 12 * time.Hour
)

var errWebPushPayloadTooLarge = errors.New("webpush payload exceeds one 4096-octet record")

// WebPushSubscription is what a UnifiedPush distributor hands the app: the
// endpoint to POST to, plus the device's P-256 public key and auth secret used
// for RFC 8291 encryption. The Android client registers it as the device's
// pushToken (JSON-encoded).
type WebPushSubscription struct {
	Endpoint string `json:"endpoint"`
	P256DH   string `json:"p256dh"`
	Auth     string `json:"auth"`

	endpointURL *url.URL
	uaPublic    *ecdh.PublicKey
	authSecret  []byte
}

// ParseWebPushSubscription validates a JSON-encoded subscription. Endpoints
// must be https: the server POSTs to an address supplied by a paired device,
// so plaintext and non-web schemes are refused.
func ParseWebPushSubscription(raw string) (WebPushSubscription, error) {
	var sub WebPushSubscription
	if err := json.Unmarshal([]byte(strings.TrimSpace(raw)), &sub); err != nil {
		return WebPushSubscription{}, errors.New("unifiedpush subscription is not valid JSON")
	}
	sub.Endpoint = strings.TrimSpace(sub.Endpoint)
	u, err := url.Parse(sub.Endpoint)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil {
		return WebPushSubscription{}, errors.New("unifiedpush endpoint must be an https URL")
	}
	keyBytes, err := decodeBase64URL(sub.P256DH)
	if err != nil {
		return WebPushSubscription{}, errors.New("unifiedpush p256dh is not base64url")
	}
	uaPublic, err := ecdh.P256().NewPublicKey(keyBytes)
	if err != nil {
		return WebPushSubscription{}, errors.New("unifiedpush p256dh is not a P-256 public key")
	}
	authSecret, err := decodeBase64URL(sub.Auth)
	if err != nil || len(authSecret) != 16 {
		return WebPushSubscription{}, errors.New("unifiedpush auth secret must be 16 bytes")
	}
	sub.endpointURL = u
	sub.uaPublic = uaPublic
	sub.authSecret = authSecret
	return sub, nil
}

// EndpointHost is the distributor host (e.g. ntfy.example.com or
// fcm.googleapis.com) — safe to display; the full endpoint is a capability URL
// and must not be logged or shown.
func (s WebPushSubscription) EndpointHost() string {
	if s.endpointURL == nil {
		return ""
	}
	return s.endpointURL.Hostname()
}

// WebPushProvider delivers notifications to UnifiedPush distributors.
type WebPushProvider struct {
	vapid   *ecdsa.PrivateKey
	subject string
	client  *http.Client
	ttl     time.Duration
	prune   func(deviceID string)
	now     func() time.Time
	random  io.Reader
}

func NewWebPushProvider(vapid *ecdsa.PrivateKey, subject string, client *http.Client, ttl time.Duration, prune func(string), privateHosts ...string) *WebPushProvider {
	if client == nil {
		client = &http.Client{Timeout: 15 * time.Second}
	}
	// Never follow redirects: the endpoint was supplied by a device and a
	// redirect could point the Mac at another host.
	guarded := *client
	transport := http.DefaultTransport.(*http.Transport).Clone()
	if configured, ok := client.Transport.(*http.Transport); ok {
		transport = configured.Clone()
	}
	transport.Proxy = nil
	transport.DialTLSContext = nil
	transport.DialTLS = nil
	transport.DialContext = webPushDialer(privateHosts)
	guarded.Transport = transport
	guarded.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	if ttl <= 0 {
		ttl = 24 * time.Hour
	}
	return &WebPushProvider{vapid: vapid, subject: subject, client: &guarded, ttl: ttl, prune: prune, now: time.Now, random: rand.Reader}
}

func (p *WebPushProvider) Send(ctx context.Context, device store.DeviceRecord, notification Notification) error {
	if device.PushToken == nil || strings.TrimSpace(*device.PushToken) == "" {
		return ErrPushNotConfigured
	}
	sub, err := ParseWebPushSubscription(*device.PushToken)
	if err != nil {
		return err
	}
	body, err := p.encryptNotification(sub, notification)
	if err != nil {
		return err
	}
	authorization, err := vapidAuthorization(sub.endpointURL, p.vapid, p.subject, p.now(), p.random)
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, sub.Endpoint, bytes.NewReader(body))
	if err != nil {
		return errors.New("webpush: could not build request")
	}
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("Content-Encoding", "aes128gcm")
	req.Header.Set("TTL", strconv.FormatInt(int64(p.ttl/time.Second), 10))
	req.Header.Set("Urgency", "high")
	req.Header.Set("Authorization", authorization)

	resp, err := p.client.Do(req)
	if err != nil {
		// *url.Error embeds the endpoint (a capability URL). Keep only the cause.
		var urlErr *url.Error
		if errors.As(err, &urlErr) {
			err = urlErr.Err
		}
		return fmt.Errorf("webpush send to %s: %w", sub.EndpointHost(), err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 512))

	switch {
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		return nil
	case resp.StatusCode == http.StatusNotFound || resp.StatusCode == http.StatusGone:
		// RFC 8030 §6.2: the subscription expired or was removed.
		if p.prune != nil {
			p.prune(device.ID)
		}
		return nil
	case resp.StatusCode == http.StatusRequestEntityTooLarge:
		return nil // already sized to one record; tolerate like FCM
	default:
		return fmt.Errorf("webpush send to %s failed: HTTP %d", sub.EndpointHost(), resp.StatusCode)
	}
}

// encryptNotification serialises the shared push data map and encrypts it,
// dropping the preview body if escaping pushes it past one record.
func (p *WebPushProvider) encryptNotification(sub WebPushSubscription, n Notification) ([]byte, error) {
	for _, maxBody := range []int{webPushMaxBodyChars, 0} {
		plaintext, err := json.Marshal(notificationData(n, maxBody))
		if err != nil {
			return nil, err
		}
		asPrivate, err := ecdh.P256().GenerateKey(p.random)
		if err != nil {
			return nil, err
		}
		salt := make([]byte, 16)
		if _, err := io.ReadFull(p.random, salt); err != nil {
			return nil, err
		}
		body, err := encryptWebPush(plaintext, sub.uaPublic, sub.authSecret, asPrivate, salt)
		if errors.Is(err, errWebPushPayloadTooLarge) {
			continue
		}
		return body, err
	}
	return nil, errWebPushPayloadTooLarge
}

// encryptWebPush implements RFC 8291 §3.4 with a single aes128gcm record
// (RFC 8188). asPrivate and salt must be fresh for every message.
func encryptWebPush(plaintext []byte, uaPublic *ecdh.PublicKey, authSecret []byte, asPrivate *ecdh.PrivateKey, salt []byte) ([]byte, error) {
	if len(salt) != 16 {
		return nil, errors.New("webpush salt must be 16 bytes")
	}
	if webPushHeaderLen+len(plaintext)+webPushOverhead > webPushMaxBody {
		return nil, errWebPushPayloadTooLarge
	}
	ecdhSecret, err := asPrivate.ECDH(uaPublic)
	if err != nil {
		return nil, err
	}
	uaBytes := uaPublic.Bytes()
	asBytes := asPrivate.PublicKey().Bytes()

	keyInfo := make([]byte, 0, 14+len(uaBytes)+len(asBytes))
	keyInfo = append(keyInfo, "WebPush: info\x00"...)
	keyInfo = append(keyInfo, uaBytes...)
	keyInfo = append(keyInfo, asBytes...)
	ikm, err := hkdf.Key(sha256.New, ecdhSecret, authSecret, string(keyInfo), 32)
	if err != nil {
		return nil, err
	}
	prk, err := hkdf.Extract(sha256.New, ikm, salt)
	if err != nil {
		return nil, err
	}
	cek, err := hkdf.Expand(sha256.New, prk, "Content-Encoding: aes128gcm\x00", 16)
	if err != nil {
		return nil, err
	}
	nonce, err := hkdf.Expand(sha256.New, prk, "Content-Encoding: nonce\x00", 12)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(cek)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}

	record := make([]byte, 0, len(plaintext)+1)
	record = append(record, plaintext...)
	record = append(record, 0x02) // last-record padding delimiter

	out := make([]byte, 0, webPushHeaderLen+len(record)+gcm.Overhead())
	out = append(out, salt...)
	out = binary.BigEndian.AppendUint32(out, webPushRecordSize)
	out = append(out, byte(len(asBytes)))
	out = append(out, asBytes...)
	return gcm.Seal(out, nonce, record, nil), nil
}

// vapidAuthorization builds the RFC 8292 `vapid t=<JWT>, k=<public key>`
// header for the endpoint's origin.
func vapidAuthorization(endpoint *url.URL, key *ecdsa.PrivateKey, subject string, now time.Time, random io.Reader) (string, error) {
	if key == nil {
		return "", ErrPushNotConfigured
	}
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"typ":"JWT","alg":"ES256"}`))
	claims, err := json.Marshal(map[string]any{
		"aud": endpoint.Scheme + "://" + endpoint.Host,
		"exp": now.Add(vapidTokenLifetime).Unix(),
		"sub": subject,
	})
	if err != nil {
		return "", err
	}
	signingInput := header + "." + base64.RawURLEncoding.EncodeToString(claims)
	digest := sha256.Sum256([]byte(signingInput))
	r, s, err := ecdsa.Sign(random, key, digest[:])
	if err != nil {
		return "", err
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	publicKey, err := VAPIDPublicKey(key)
	if err != nil {
		return "", err
	}
	return "vapid t=" + signingInput + "." + base64.RawURLEncoding.EncodeToString(sig) + ", k=" + publicKey, nil
}

// decodeBase64URL accepts base64url or standard base64, padded or not —
// distributors and client libraries differ.
func decodeBase64URL(value string) ([]byte, error) {
	value = strings.TrimSpace(value)
	value = strings.TrimRight(value, "=")
	value = strings.NewReplacer("+", "-", "/", "_").Replace(value)
	return base64.RawURLEncoding.DecodeString(value)
}

// Resolve and validate at connection time, then dial the checked IP directly.
// This prevents DNS rebinding and proxy environment variables bypassing policy.
func webPushDialer(privateHosts []string) func(context.Context, string, string) (net.Conn, error) {
	allowed := map[string]bool{}
	for _, host := range privateHosts {
		allowed[strings.ToLower(strings.TrimSuffix(strings.TrimSpace(host), "."))] = true
	}
	return func(ctx context.Context, network, address string) (net.Conn, error) {
		host, port, err := net.SplitHostPort(address)
		if err != nil {
			return nil, errors.New("invalid push endpoint address")
		}
		ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
		if err != nil {
			return nil, errors.New("push endpoint DNS lookup failed")
		}
		if len(ips) == 0 {
			return nil, errors.New("push endpoint has no addresses")
		}
		privateAllowed := allowed[strings.ToLower(strings.TrimSuffix(host, "."))]
		for _, ip := range ips {
			if !webPushIPAllowed(ip, privateAllowed) {
				return nil, errors.New("push endpoint address is not allowed")
			}
		}
		dialer := net.Dialer{Timeout: 10 * time.Second}
		for _, ip := range ips {
			conn, err := dialer.DialContext(ctx, network, net.JoinHostPort(ip.String(), port))
			if err == nil {
				return conn, nil
			}
		}
		return nil, errors.New("push endpoint connection failed")
	}
}

var webPushReservedNetworks = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"),
	netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("192.0.0.0/24"),
	netip.MustParsePrefix("192.0.2.0/24"),
	netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("198.51.100.0/24"),
	netip.MustParsePrefix("203.0.113.0/24"),
	netip.MustParsePrefix("240.0.0.0/4"),
	// Exclude the IETF protocol assignment block, including Teredo,
	// even where individual special-purpose allocations are reachable.
	netip.MustParsePrefix("2001::/23"),
	netip.MustParsePrefix("2001:db8::/32"),
	netip.MustParsePrefix("2002::/16"),
	netip.MustParsePrefix("3ffe::/16"), // Former 6bone and legacy Teredo.
	netip.MustParsePrefix("3fff::/20"), // Documentation (RFC 9637).
}

func webPushIPAllowed(ip netip.Addr, privateAllowed bool) bool {
	ip = ip.Unmap()
	if ip.IsLoopback() || ip.IsPrivate() {
		return privateAllowed
	}
	if !ip.IsGlobalUnicast() {
		return false
	}
	for _, prefix := range webPushReservedNetworks {
		if prefix.Contains(ip) {
			return false
		}
	}
	// Public IPv6 is allocated within 2000::/3. Other ranges include local
	// translation/tunneling addresses that must not bypass the IPv4 checks.
	return ip.Is4() || netip.MustParsePrefix("2000::/3").Contains(ip)
}

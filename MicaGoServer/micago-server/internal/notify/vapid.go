package notify

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// LoadOrCreateVAPIDKey reads the server's VAPID signing key, generating and
// persisting a new P-256 key (0600, PEM "EC PRIVATE KEY") on first use. The key
// identifies this Mac to push services; it never leaves the Mac. Replacing it
// invalidates every existing UnifiedPush subscription that was bound to the
// old public key (FCM enforces this), so devices must re-register.
func LoadOrCreateVAPIDKey(path string) (*ecdsa.PrivateKey, error) {
	if path == "" {
		return nil, ErrPushNotConfigured
	}
	raw, err := os.ReadFile(path)
	if err == nil {
		return parseVAPIDKey(raw)
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("read vapid key: %w", err)
	}

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	der, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("create vapid key directory: %w", err)
	}
	// Publish only a complete key. Concurrent readers must never see a
	// partially written PEM, and concurrent creators must reuse the winner.
	f, err := os.CreateTemp(filepath.Dir(path), ".vapid-*.pem")
	if err != nil {
		return nil, errors.New("create temporary vapid key failed")
	}
	defer os.Remove(f.Name())
	if err := pem.Encode(f, &pem.Block{Type: "EC PRIVATE KEY", Bytes: der}); err != nil {
		f.Close()
		return nil, errors.New("write vapid key failed")
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return nil, errors.New("sync vapid key failed")
	}
	if err := f.Close(); err != nil {
		return nil, errors.New("close vapid key failed")
	}
	if err := os.Link(f.Name(), path); errors.Is(err, os.ErrExist) {
		return LoadOrCreateVAPIDKey(path)
	} else if err != nil {
		return nil, errors.New("publish vapid key failed")
	}

	return key, nil
}

func parseVAPIDKey(raw []byte) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode(raw)
	if block == nil || block.Type != "EC PRIVATE KEY" {
		return nil, errors.New("vapid key file is not a PEM EC private key")
	}
	key, err := x509.ParseECPrivateKey(block.Bytes)
	if err != nil {
		return nil, errors.New("vapid key file could not be parsed")
	}
	if key.Curve != elliptic.P256() {
		return nil, errors.New("vapid key must use P-256")
	}
	return key, nil
}

// VAPIDPublicKey returns the uncompressed public key, base64url without
// padding — the form UnifiedPush/WebPush clients expect as applicationServerKey.
func VAPIDPublicKey(key *ecdsa.PrivateKey) (string, error) {
	if key == nil {
		return "", ErrPushNotConfigured
	}
	pub, err := key.PublicKey.ECDH()
	if err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(pub.Bytes()), nil
}

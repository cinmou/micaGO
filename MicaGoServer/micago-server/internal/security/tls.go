// Package security uses the standard library TLS implementation. Pairing pins
// the persisted server certificate; no application-layer crypto is introduced.
package security

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"time"
)

func ServerTLS(dir string) (*tls.Config, string, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, "", err
	}
	if err := os.Chmod(dir, 0700); err != nil {
		return nil, "", err
	}
	certPath, keyPath := filepath.Join(dir, "server.crt"), filepath.Join(dir, "server.key")
	_, certErr := os.Stat(certPath)
	_, keyErr := os.Stat(keyPath)
	if os.IsNotExist(certErr) && os.IsNotExist(keyErr) {
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			return nil, "", err
		}
		serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
		if err != nil {
			return nil, "", err
		}
		now := time.Now()
		tmpl := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: "micaGO"}, NotBefore: now.Add(-time.Hour), NotAfter: now.AddDate(10, 0, 0), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, DNSNames: []string{"micago.local"}}
		der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
		if err != nil {
			return nil, "", err
		}
		private, err := x509.MarshalPKCS8PrivateKey(key)
		if err != nil {
			return nil, "", err
		}
		if err = os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: private}), 0600); err != nil {
			return nil, "", err
		}
		if err = os.WriteFile(certPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0600); err != nil {
			return nil, "", err
		}
	}
	// A partial/damaged identity fails closed rather than silently changing pins.
	pair, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		return nil, "", fmt.Errorf("load server TLS identity: %w", err)
	}
	for _, p := range []string{certPath, keyPath} {
		if err = os.Chmod(p, 0600); err != nil {
			return nil, "", err
		}
	}
	leaf, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		return nil, "", err
	}
	if time.Now().After(leaf.NotAfter) {
		return nil, "", fmt.Errorf("server TLS certificate expired; replace identity and re-pair devices")
	}
	hash := sha256.Sum256(pair.Certificate[0])
	return &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{pair}}, hex.EncodeToString(hash[:]), nil
}

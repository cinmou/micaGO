package config

import (
	"reflect"
	"regexp"
	"strings"
	"testing"
)

// legacyRenderedConfig is a byte-for-byte sample of what the old handwritten
// renderConfig (strings.Join + strconv.Quote) wrote to disk, with non-default
// values in every section. Files like this exist on user machines; the yaml.v3
// parser must keep reading them.
const legacyRenderedConfig = `server:
  addr: "192.168.1.10:3100"
  public_url: "https://legacy.example.com"

network:
  public_base_url: "https://tunnel.example.com"
  verify_tls: false
  preferred_pairing_endpoint: "lan"

auth:
  token: "deadbeefcafe0123"

sync:
  interval: "10s"
  update_lookback: "24h0m0s"

notifications:
  enabled: true
  provider: "fcm"
  preview: "sender_and_text"

webhook:
  url: "https://hook.example.com/notify"

fcm:
  enabled: true
  project_id: "my-project"
  service_account_path: "~/.micago/sa.json"
  google_services_path: "~/.micago/google-services.json"

hms:
  enabled: true
  app_id: "hms-app"
  app_secret: "hms-secret"
  token_cache_path: "~/.micago/hms-token.json"

firebase:
  public_url_sync: true
  url_collection: "servers"
  url_document: "primary"
`

func TestParseLegacyHandwrittenConfig(t *testing.T) {
	cfg, err := parseConfig(legacyRenderedConfig)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Server.Addr != "192.168.1.10:3100" || cfg.Server.PublicURL != "https://legacy.example.com" {
		t.Fatalf("server section mismatch: %+v", cfg.Server)
	}
	if cfg.Network.PublicBaseURL != "https://tunnel.example.com" || cfg.Network.VerifyTLS || cfg.Network.PreferredPairingEndpoint != "lan" {
		t.Fatalf("network section mismatch: %+v", cfg.Network)
	}
	if cfg.Auth.Token != "deadbeefcafe0123" {
		t.Fatalf("auth token mismatch: %q", cfg.Auth.Token)
	}
	if cfg.Sync.Interval != "10s" || cfg.Sync.UpdateLookback != "24h0m0s" {
		t.Fatalf("sync section mismatch: %+v", cfg.Sync)
	}
	if !cfg.Notifications.Enabled || cfg.Notifications.Provider != "fcm" || cfg.Notifications.Preview != "sender_and_text" {
		t.Fatalf("notifications section mismatch: %+v", cfg.Notifications)
	}
	if cfg.Webhook.URL != "https://hook.example.com/notify" {
		t.Fatalf("webhook url mismatch: %q", cfg.Webhook.URL)
	}
	if !cfg.FCM.Enabled || cfg.FCM.ProjectID != "my-project" || cfg.FCM.ServiceAccountPath != "~/.micago/sa.json" || cfg.FCM.GoogleServicesPath != "~/.micago/google-services.json" {
		t.Fatalf("fcm section mismatch: %+v", cfg.FCM)
	}
	if !cfg.HMS.Enabled || cfg.HMS.AppID != "hms-app" || cfg.HMS.AppSecret != "hms-secret" || cfg.HMS.TokenCachePath != "~/.micago/hms-token.json" {
		t.Fatalf("hms section mismatch: %+v", cfg.HMS)
	}
	if !cfg.Firebase.PublicURLSync || cfg.Firebase.URLCollection != "servers" || cfg.Firebase.URLDocument != "primary" {
		t.Fatalf("firebase section mismatch: %+v", cfg.Firebase)
	}
}

// A legacy file must survive parse → render → parse without losing or changing
// any field (what every UpdatePublicBaseURL / UpdateNotificationsConfig call
// does to an existing config).
func TestLegacyConfigRoundTripsThroughNewRenderer(t *testing.T) {
	first, err := parseConfig(legacyRenderedConfig)
	if err != nil {
		t.Fatal(err)
	}
	rendered, err := renderConfig(first)
	if err != nil {
		t.Fatal(err)
	}
	second, err := parseConfig(rendered)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(first, second) {
		t.Fatalf("round-trip changed config:\nfirst:  %+v\nsecond: %+v", first, second)
	}
	// The renderer keeps the legacy byte format exactly, so a round-tripped
	// legacy file is byte-identical too.
	if rendered != legacyRenderedConfig {
		t.Fatalf("rendered output diverged from legacy format:\n%s", rendered)
	}
}

// The written format is consumed outside this package: the Companion's
// ConfigReader.swift line-parses it and the smoke scripts extract values with
// `sed -n 's/^  token: "\(.*\)"$/\1/p'`. Guard the exact shape those depend
// on: bare 2-space-indented keys, double-quoted string values, bare bools.
func TestRenderedConfigKeepsExternalParserFormat(t *testing.T) {
	rendered, err := renderConfig(defaultFileConfig("sekret-token"))
	if err != nil {
		t.Fatal(err)
	}
	for _, pattern := range []string{
		`(?m)^  token: "sekret-token"$`,
		`(?m)^  addr: "0\.0\.0\.0:3000"$`,
		`(?m)^  url: ""$`,
		`(?m)^  verify_tls: true$`,
		`(?m)^server:$`,
	} {
		if !regexp.MustCompile(pattern).MatchString(rendered) {
			t.Fatalf("rendered config no longer matches %s:\n%s", pattern, rendered)
		}
	}
	if strings.Contains(rendered, `"token":`) {
		t.Fatalf("keys must stay unquoted:\n%s", rendered)
	}
}

// Files hand-edited or written by other/newer versions: unknown keys and
// sections must be ignored, absent ones must fall back to defaults.
func TestParseConfigToleratesUnknownAndMissingKeys(t *testing.T) {
	cfg, err := parseConfig(`# hand-edited
auth:
  token: abc            # unquoted value, trailing comment
  future_key: whatever
experimental:
  flag: true
`)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Auth.Token != "abc" {
		t.Fatalf("token = %q", cfg.Auth.Token)
	}
	if cfg.Server.Addr != "0.0.0.0:3000" || !cfg.Network.VerifyTLS || cfg.Notifications.Provider != "none" {
		t.Fatalf("defaults not applied: %+v", cfg)
	}
}

package notify

import (
	"encoding/json"
	"errors"
	"os"
	"strings"
)

// FirebaseClientConfig is the subset of a user's google-services.json that the
// Flutter app needs to initialize Firebase at runtime (C22) — the same values
// the BlueBubbles app pulls from the server. It contains no secrets: an FCM API
// key + app/sender/project ids are public client identifiers, not credentials.
type FirebaseClientConfig struct {
	Configured        bool   `json:"configured"`
	ProjectID         string `json:"projectId"`
	AppID             string `json:"appId"`
	APIKey            string `json:"apiKey"`
	MessagingSenderID string `json:"messagingSenderId"`
	StorageBucket     string `json:"storageBucket"`
}

// google-services.json shape (only the fields we read).
type googleServicesFile struct {
	ProjectInfo struct {
		ProjectNumber string `json:"project_number"`
		ProjectID     string `json:"project_id"`
		StorageBucket string `json:"storage_bucket"`
	} `json:"project_info"`
	Client []struct {
		ClientInfo struct {
			MobilesdkAppID string `json:"mobilesdk_app_id"`
		} `json:"client_info"`
		APIKey []struct {
			CurrentKey string `json:"current_key"`
		} `json:"api_key"`
	} `json:"client"`
}

// LoadFirebaseClientConfig parses the client config from a google-services.json
// at [path]. Returns an unconfigured (zero) config with no error when the path
// is empty, so the endpoint degrades cleanly when Firebase isn't set up.
func LoadFirebaseClientConfig(path string) (FirebaseClientConfig, error) {
	if strings.TrimSpace(path) == "" {
		return FirebaseClientConfig{Configured: false}, nil
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return FirebaseClientConfig{Configured: false}, err
	}
	var gs googleServicesFile
	if err := json.Unmarshal(raw, &gs); err != nil {
		return FirebaseClientConfig{Configured: false}, err
	}
	if len(gs.Client) == 0 {
		return FirebaseClientConfig{Configured: false}, errors.New("google-services.json has no client entry")
	}
	client := gs.Client[0]
	apiKey := ""
	if len(client.APIKey) > 0 {
		apiKey = client.APIKey[0].CurrentKey
	}
	cfg := FirebaseClientConfig{
		Configured:        true,
		ProjectID:         gs.ProjectInfo.ProjectID,
		AppID:             client.ClientInfo.MobilesdkAppID,
		APIKey:            apiKey,
		MessagingSenderID: gs.ProjectInfo.ProjectNumber,
		StorageBucket:     gs.ProjectInfo.StorageBucket,
	}
	if strings.TrimSpace(cfg.ProjectID) == "" || strings.TrimSpace(cfg.AppID) == "" ||
		strings.TrimSpace(cfg.APIKey) == "" || strings.TrimSpace(cfg.MessagingSenderID) == "" {
		return FirebaseClientConfig{Configured: false}, errors.New("google-services.json is missing required client fields")
	}
	return cfg, nil
}

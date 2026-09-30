package store

type MessagePreference struct {
	MessageKey string `json:"messageKey"`
	Hidden     bool   `json:"hidden"`
	Revision   int64  `json:"revision"`
}

type MessagePreferences struct {
	ServerID string              `json:"serverId"`
	Revision int64               `json:"revision"`
	Data     []MessagePreference `json:"data"`
}

type MessagePreferenceChange struct {
	MessageKey   string `json:"messageKey"`
	Hidden       bool   `json:"hidden"`
	BaseRevision int64  `json:"baseRevision"`
}

type MessagePreferenceMutation struct {
	ServerID   string                    `json:"serverId"`
	MutationID string                    `json:"mutationId"`
	Changes    []MessagePreferenceChange `json:"changes"`
}

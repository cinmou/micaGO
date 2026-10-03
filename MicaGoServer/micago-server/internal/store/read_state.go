package store

type ReadPosition struct {
	ChatGUID           string `json:"chatGuid"`
	ReadThrough        int64  `json:"readThrough"`
	MarkedUnread       *bool  `json:"markedUnread,omitempty"`
	UnreadRevision     int64  `json:"unreadRevision,omitempty"`
	BaseUnreadRevision *int64 `json:"baseUnreadRevision,omitempty"`
}
type ReadState struct {
	ServerID string         `json:"serverId"`
	Revision int64          `json:"revision"`
	Data     []ReadPosition `json:"data"`
}
type ReadStateMutation struct {
	ServerID string         `json:"serverId"`
	Changes  []ReadPosition `json:"changes"`
}

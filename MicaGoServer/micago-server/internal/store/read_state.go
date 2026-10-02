package store

type ReadPosition struct {
	ChatGUID    string `json:"chatGuid"`
	ReadThrough int64  `json:"readThrough"`
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

package notify

import (
	"context"
	"errors"

	"micagoserver/internal/store"
)

var ErrPushNotConfigured = errors.New("push not configured")

type Provider interface {
	Send(ctx context.Context, device store.DeviceRecord, notification Notification) error
}

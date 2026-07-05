# MicaGoServer v0.8.0 Notification Provider Abstraction

## Goal

Add a provider abstraction so notification delivery can evolve without coupling push logic to sync, relay, REST, or send confirmation code.

## Design

Package:

- `internal/notify/`

Core interface:

```go
type Provider interface {
    Name() string
    Send(ctx context.Context, device Device, notification Notification) error
}
```

Notification payload:

```go
type Notification struct {
    Type string
    MessageGUID string
    ChatGUID string
    Title string
    Body string
    PreviewMode string
    CreatedAt int64
}
```

## Current Providers

- `none`
- `webhook`
- `fcm` stub
- `hms` stub
- `harmony_push` stub
- `ntfy` stub

Current behavior:

- `none`: no-op provider
- `webhook`: POST JSON to configured `webhook.url`
- `fcm`: returns `not_implemented`
- `hms`: returns `not_implemented`
- `harmony_push`: returns `not_implemented`
- `ntfy`: returns `not_implemented`

## Dispatch Behavior

Trigger:

- When relay sync discovers newly inserted messages

Default rules:

- Only incoming messages are pushed by default
- Outgoing `isFromMe=true` messages do not trigger push by default
- Attachment file data is never included

Preview behavior:

- `none`
  - title: `New iMessage`
  - body: `""`
- `sender`
  - title: `New iMessage`
  - body: chat display name or chat identifier
- `sender_and_text`
  - title: chat display name or chat identifier
  - body: extracted message text preview

## Notification Test Endpoint

Endpoint:

- `POST /api/server/notifications/test`

Behavior:

- If no device has registered, returns `push_no_devices`
- If no device has an enabled FCM token, returns `push_no_fcm_devices`
- If the provider exists only as a stub, returns `not_implemented`
- If webhook delivery is configured, it posts a test payload

## Flutter / Android Note

- FCM is the planned provider for Google Android clients.
- The abstraction is already in place so a real FCM implementation can be added without rewriting sync or message APIs.

## Huawei / HarmonyOS Note

- HMS / Huawei Push is planned through the same provider abstraction.
- `hms` and `harmony_push` are intentionally separate identifiers at the registry level so future client behavior can stay explicit.

## Windows Note

- Windows does not need FCM.
- Planned behavior is WebSocket plus tray integration plus native Windows notifications.

## Manual Test Plan

1. Start the server with notifications disabled and register a `none` provider device.
2. Call `POST /api/server/notifications/test` and confirm `push_no_fcm_devices`.
3. Configure `webhook.url`, enable notifications, register a webhook device, and call the notification test.
4. Confirm the webhook receives a privacy-conscious JSON payload.
5. Register an `fcm` device and confirm the notification test returns `not_implemented`.
6. Receive a real incoming iMessage and confirm the dispatcher runs only for incoming messages.

## Known Limitations

- Real FCM delivery is not implemented yet.
- Real HMS / Harmony Push delivery is not implemented yet.
- Active WebSocket connections are not yet mapped to devices for push suppression.
- Notification routing is global-server-token based, not per-device auth scoped yet.

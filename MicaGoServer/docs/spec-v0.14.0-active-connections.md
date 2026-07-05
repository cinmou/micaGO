# MicaGoServer v0.14.0 Active Connections

## Goal

Expose a privacy-focused list of clients that are currently connected to the
server. This powers the Companion's **Paired Devices** view.

This is intentionally separate from the device registry:

- **Active connections / Paired Devices**: live authenticated WebSocket sessions.
- **Push devices**: optional FCM/webhook/HMS/etc registration rows used for
  notification delivery and the unified notification test.

## API

`GET /api/server/connections`

```json
{
  "data": [
    {
      "id": "ws_...",
      "clientName": "micaGO Android",
      "clientType": "flutter",
      "platform": "android",
      "appVersion": "0.1.0",
      "remoteAddress": "192.168.1.42",
      "userAgent": "...",
      "connectedAt": 1717372800000,
      "lastSeenAt": 1717372801000
    }
  ]
}
```

The endpoint is bearer-token protected, like the rest of the control API.

## Privacy Boundary

The connection list is in-memory and ephemeral. It does not store contacts,
message content, push tokens, or stable hardware identifiers. Clients may send
low-sensitivity display metadata on WebSocket connect (`name`, `clientType`,
`platform`, `appVersion`) so the Companion can show a readable row.

FCM registration remains optional and continues to use `/api/devices/register`
and `/api/devices`.

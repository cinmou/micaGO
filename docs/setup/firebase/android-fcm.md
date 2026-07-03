# Add Android / FCM

This enables your **Android client** to obtain an FCM registration token and
receive push from micaGO. (The server side only needs the
[service account](service-account.md).)

1. Firebase Console → **Project settings** → **General** → **Your apps** → **Add
   app** → **Android**.
2. Enter your Android app's **package name**, register, and download the
   generated **`google-services.json`**. This file is for the **Android client
   app**, not the micaGO server.
3. Build the Android client with that `google-services.json` so it can call
   `FirebaseMessaging.getToken()`.

## Registering the token with micaGO

The Android client registers its FCM token with the relay using the existing
device registry (see `docs/spec-v0.7.0-device-registry.md`):

```
POST /api/devices/register
{ "name": "Pixel", "platform": "android", "clientType": "flutter",
  "pushProvider": "fcm", "pushToken": "<FCM registration token>", "pushEnabled": true }
```

- The push token is stored only in the local `relay.db` and is sent to **Google
  FCM** as the delivery address — it is never published in any Firestore
  document. The companion only ever shows `token set`, never the token itself.
- If FCM later reports the token as `UNREGISTERED`, micaGO prunes it (clears the
  token and disables push for that device) so dead tokens don't accumulate.

## What the push looks like

micaGO sends an FCM **HTTP v1 `data` message** (high priority, 24h TTL):

```json
{ "message": { "token": "<device token>",
  "data": { "type": "message:new", "messageGuid": "...", "chatGuid": "...",
            "title": "...", "body": "...", "previewMode": "sender", "createdAt": "1717..." },
  "android": { "priority": "high", "ttl": "86400s" } } }
```

`title`/`body` content is gated by your **Preview** setting (see
[privacy-boundaries.md](privacy-boundaries.md)). The Android client renders the
local notification from this data payload.

> Test it end-to-end from the companion: **Devices → Test Push**.

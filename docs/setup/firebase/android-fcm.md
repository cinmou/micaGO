# Add Android / FCM

This enables your **Android client** to obtain an FCM registration token and
receive push from micaGO. (The server side only needs the
[service account](service-account.md).)

1. Firebase Console → **Project settings** → **General** → **Your apps** → **Add
   app** → **Android**.
2. Enter your Android app's **package name**, register, and download the
   generated **`google-services.json`**.
3. In the micaGO Companion, open **Notifications** and choose that
   `google-services.json`. The Flutter client fetches the config from your server
   and initializes Firebase at runtime; the file is not baked into the APK.

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

micaGO sends a **data-only** FCM HTTP v1 message (high priority, 24h TTL):

```json
{ "message": { "token": "<device token>",
  "data": { "type": "message:new", "messageGuid": "...", "chatGuid": "...",
            "title": "...", "body": "...", "previewMode": "sender", "createdAt": "1717..." },
  "android": { "priority": "high", "ttl": "86400s" } } }
```

Android does not render this payload directly. The micaGO client receives the
data message, renders the same local MessagingStyle notification used by the
keep-alive path, and then syncs the actual message through the normal micaGO
connection.

> Test it end-to-end from the companion: **Notifications → Send test notification**.

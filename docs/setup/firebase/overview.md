# micaGO Firebase Setup (self-host)

micaGO can deliver **Android push notifications** through **Firebase Cloud
Messaging (FCM)** and, optionally, publish your **public server URL** to your own
**Firestore** so remote clients can rediscover a changed tunnel URL.

> **micaGO does not run a cloud server.** There is no Mica-operated relay or
> Mica-operated Firebase. **You bring your own Firebase project.** Your service
> account and data stay in *your* Google project and on *your* Mac.

## What Firebase is (and isn't) used for

- ✅ **Android FCM push** — wake/notify an Android client when a new iMessage
  arrives (content gated by your Preview setting).
- ✅ **Optional public-URL discovery** — write *only* the public server URL to a
  single Firestore document so remote clients can find a changed tunnel URL.
- ❌ Not a message store, not chat history, not a contact directory, not a token
  vault. See [privacy-boundaries.md](privacy-boundaries.md).

## Other platforms

- The current first-party mobile client is Android.
- **Huawei / HarmonyOS Push Kit**: deferred (not implemented).
- **iOS push**: out of scope.

## Setup order

1. [Create a Firebase project](create-firebase-project.md)
2. [Add Android / FCM to the project](android-fcm.md)
3. [Create a service account for the server](service-account.md)
4. Point micaGO at it: Companion → **Notifications** → provider **FCM**, choose
   the service-account JSON, set **Preview**, enable, **Save**. (Or edit
   `~/.micago/config.yaml`, see below.)
5. (Optional) [Enable Firestore public-URL sync](firestore-server-url-sync.md)
6. [Privacy boundaries](privacy-boundaries.md) — what is and isn't sent.
7. [Troubleshooting](troubleshooting.md)

## Config keys (`~/.micago/config.yaml`)

```yaml
notifications:
  enabled: true
  provider: "fcm"          # none | webhook | fcm
  preview: "sender"        # none | sender | sender_and_text
fcm:
  enabled: true
  project_id: ""           # optional; inferred from the service account
  service_account_path: "~/.micago/firebase-service-account.json"
firebase:
  public_url_sync: false   # optional Firestore public-URL sync
  url_collection: "server" # Firestore collection
  url_document: "config"   # Firestore document
```

The companion writes these via `POST /api/server/notifications` (it never sends
or stores the service-account contents — only the file path on the Mac).

## Verify

- Companion → **Notifications** shows **configured (fcm)** once the service
  account loads; `GET /api/server/status` lists `fcm` under
  `notifications.implemented`.
- Companion → **Devices** → **Test Push** delivers a real notification to a
  registered Android device.

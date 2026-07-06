# micaGO Firebase Setup (self-host)

micaGO can deliver **Android push notifications** through **Firebase Cloud
Messaging (FCM)** and, optionally, publish your **public server URL** to your own
**Firestore** so remote clients can rediscover a changed tunnel URL.

> **Firebase setup is self-hosted.** You bring your own Firebase project. Your
> service account and configuration stay in *your* Google project and on *your*
> Mac.

## What Firebase is used for

- **Android FCM push** — wake/notify an Android client when a new iMessage
  arrives.
- **Optional public-URL discovery** — write the public server URL to a
  single Firestore document so remote clients can find a changed tunnel URL.
- **Data boundary** — Firebase is used for notification delivery and optional URL
  discovery. See [privacy-boundaries.md](privacy-boundaries.md).

## Other platforms

- The current first-party mobile client is Android.
- **Huawei / HarmonyOS Push Kit**: deferred (not implemented).
- **iOS push**: out of scope.

## Setup order

1. [Create a Firebase project](create-firebase-project.md)
2. [Add Android / FCM to the project](android-fcm.md)
3. [Create a service account for the server](service-account.md), then grant it
   **Firebase Cloud Messaging API Admin** in Google Cloud IAM.
4. Point micaGO at it: Companion → **Notifications** → enable FCM, choose
   `google-services.json`, choose the service-account JSON, and save.
5. (Optional) [Enable Firestore public-URL sync](firestore-server-url-sync.md)
6. [Privacy boundaries](privacy-boundaries.md) — what data is used for push and URL discovery.
7. [Troubleshooting](troubleshooting.md)

## Config keys (`~/.micago/config.yaml`)

```yaml
notifications:
  enabled: true
  provider: "fcm"          # none | webhook | fcm
  preview: "sender"        # retained for compatibility
fcm:
  enabled: true
  project_id: ""           # optional; inferred from the service account
  service_account_path: "~/.micago/firebase-service-account.json"
  google_services_path: "~/.micago/google-services.json"
firebase:
  public_url_sync: false   # optional Firestore public-URL sync
  url_collection: "server" # Firestore collection
  url_document: "config"   # Firestore document
```

The companion writes these via `POST /api/server/notifications`. It stores the
service-account file path on the Mac.

## Verify

- Companion → **Notifications** shows **configured (fcm)** once the service
  account loads; `GET /api/server/status` lists `fcm` under
  `notifications.implemented`.
- Companion → **Notifications** → **Send test notification** delivers a real
  notification to every registered Android FCM device.

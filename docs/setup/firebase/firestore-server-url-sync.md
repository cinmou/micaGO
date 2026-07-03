# Optional: Firestore public-URL sync

If you reach the server remotely through a tunnel/reverse proxy whose URL can
change (Cloudflare Tunnel, Ngrok, DDNS, etc.), micaGO can publish **only the
current public URL** to a single Firestore document so your clients can
rediscover it. This is **optional and off by default**.

## What is written

A single document, by default `server/config`:

```
collection: server   (configurable: firebase.url_collection)
document:   config   (configurable: firebase.url_document)
fields:     { "publicBaseUrl": "<your public URL>" }
```

That is the **only** field written. No bearer token, no push tokens, no message
content, no contacts — see [privacy-boundaries.md](privacy-boundaries.md).

## Enable it

- Companion → **Notifications** → (Provider FCM configured) → toggle **Sync
  public URL to Firestore** → **Save**, **or** set in `~/.micago/config.yaml`:
  ```yaml
  firebase:
    public_url_sync: true
    url_collection: "server"
    url_document: "config"
  ```
- It reuses the same service account as FCM (scope `datastore`). Enable
  **Firestore** in your Firebase project (Console → Build → Firestore Database →
  Create database).

## When it writes

- At server startup if a public URL is already configured.
- Whenever the public URL changes via `POST /api/server/public-url` (Companion →
  Connections → Save Public URL).

## Recommended Firestore security rules

Restrict reads to your own authenticated clients and disallow public writes
(only the server, via the service account, writes). Apply in your project
(Console → Firestore → Rules), for example:

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /server/config {
      allow read: if request.auth != null;   // your signed-in clients only
      allow write: if false;                  // server uses admin credentials
    }
    match /{document=**} { allow read, write: if false; }
  }
}
```

> If you don't use a changing public URL, leave this **off** — push works without
> it.

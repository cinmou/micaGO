# Create a service account (server side)

The micaGO server authenticates to FCM (and optional Firestore) using a Google
**service account** from *your* Firebase project. This file stays on your Mac.

1. Firebase Console → **Project settings** → **Service accounts**.
2. **Generate new private key** → confirm → a JSON file downloads. It contains
   `client_email`, `private_key`, `project_id`, `token_uri`.
3. Move it somewhere private on the Mac, e.g.:
   ```
   mv ~/Downloads/your-project-*.json ~/.micago/firebase-service-account.json
   chmod 600 ~/.micago/firebase-service-account.json
   ```
4. In the companion: **Notifications** → Provider **FCM** → **Choose
   service-account JSON…** → select that file → **Enable FCM delivery** → **Save**.

## How micaGO uses it

- The server builds a short-lived **OAuth2 access token** from the service
  account (RS256-signed JWT → `token_uri`), scoped to
  `firebase.messaging` (and `datastore` if URL sync is on). Tokens are cached and
  refreshed automatically.
- It then calls the **FCM HTTP v1** endpoint
  `POST https://fcm.googleapis.com/v1/projects/<projectId>/messages:send`.

## Security

- The service-account JSON is **read from the path you choose** and **never**
  returned by any API, **never** logged, and **never** sent to clients.
- The companion stores only the **path** (e.g. in the saved config); it does not
  read or display the key contents. After import it shows only the filename.
- Treat the JSON like a password. Anyone with it can send push through your
  project. Revoke it in the Console (Service accounts → Manage keys) if leaked.

> If the file is missing, unreadable, or not a valid RSA service account, the
> companion shows **config invalid (fcm)** and FCM stays off — see
> [troubleshooting.md](troubleshooting.md).

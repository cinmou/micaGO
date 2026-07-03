# Firebase / FCM troubleshooting

## Companion shows "config invalid (fcm)"

The service-account JSON couldn't be loaded as a valid RSA service account.
- Confirm the path is correct and the file is readable by the user running the
  server.
- Confirm it's the **service account** key (has `client_email` + `private_key`),
  not the Android `google-services.json`.
- Re-download from Console → Project settings → Service accounts → Generate new
  private key, and re-select it in the companion.

## Test Push fails with "push not configured"

- The device has `pushEnabled = false`, `pushProvider = "none"`, or no push
  token. Re-register the device with `pushProvider: "fcm"` and a real FCM token.
- Notifications must be **enabled** and the provider set to **fcm** (Companion →
  Notifications → Save).

## Test Push fails with a Google error

- **403 / PERMISSION_DENIED**: the service account lacks FCM permission, or
  Cloud Messaging API is disabled. Enable "Firebase Cloud Messaging API (V1)" in
  the Google Cloud console for the project.
- **404 / UNREGISTERED**: the device token is stale. micaGO prunes it
  automatically (clears the token + disables push); re-register from the client.
- **401 / invalid_grant** when minting the token: the Mac clock may be skewed
  (JWT `iat/exp`), or the key was revoked. Fix the clock or re-issue the key.

## No push arrives, but Test Push reports success

- The Android client isn't handling the FCM `data` message, or is in a state
  where the OS suppressed it. Verify the client builds with the correct
  `google-services.json` and handles `data` messages.
- TTL is 24h; very old messages may have expired.

## Firestore URL sync errors in the log

- `firestore public-url sync: ... HTTP 403`: enable Firestore in the project and
  ensure the service account can write (admin credentials bypass rules; check the
  database exists and the API is enabled).
- Sync is **optional** — disable it (`firebase.public_url_sync: false`) if you
  don't use a changing public URL.

## Where to look

- Companion → **Logs** shows the server's stdout/stderr (tokens redacted).
- `GET /api/server/status` → `notifications.implemented` should include `fcm`
  when configured; `capabilities` shows chat.db support.
- The service-account contents never appear in logs or API responses by design.

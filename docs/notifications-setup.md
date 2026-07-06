# Notifications: setup & how it works

micaGO delivers new-message alerts to the Android client through **three layers**,
each optional and each a fallback for the one before it:

1. **Firebase / FCM push (optional, recommended).** A thin *wake* signal using
   **your own** Firebase project. Best for
   battery: the app can be fully closed and still be woken for a new message.
2. **Keep-alive foreground service (optional, no Firebase).** An Android
   foreground service holds the WebSocket open in the background and shows local
   notifications itself. Works as a local-only notification path, but **Android/OEM
   battery policy can throttle it**, especially when the screen is off for long
   periods.
3. **Delta catch-up (always on, silent).** Whenever the app resumes or the socket
   reconnects, a cursor-based sync pulls missed messages. It is the final silent
   fallback, not a notifier.

The message **content always arrives over the socket/delta path**. FCM is sent as
a **data-only** wake/awareness signal (the BlueBubbles model), and the Android
client renders the visible notification locally so FCM and keep-alive use the
same MessagingStyle surface.

## What a notification shows (C31)

- **Title = who it's from.** An on-device contact name when contacts matching is
  enabled and the sender is in your address book; otherwise the name the Mac
  knows; otherwise the raw phone/email handle. The title always resolves to a
  readable sender label.
- **Body = the message preview**, length-capped when it is carried in transient
  FCM data.
- **Native conversation style (C32).** Notifications use Android **MessagingStyle**:
  the contact's name + **avatar** (a default monogram when no photo), and
  successive messages from the same chat **stack into one conversation
  notification** instead of piling up separately.
- **Tap** opens the correct chat (after a quick delta sync so it's current) and
  dismisses that chat's notification.
- An FCM push and a keep-alive notification for the *same* message collapse into
  **one** shared notification using per-chat id + message-guid dedup.
- **Inline reply** sends the text through the paired micaGO server when the
  Android notification action is available. Tapping still opens the chat.

### Contact names & avatars: which layer resolves them

| Path | Contact name | Avatar |
| --- | --- | --- |
| Keep-alive (app alive, main isolate) | **On-device contacts** (real address-book name) | **On-device contact photo** when available, else a monogram |
| FCM background isolate | The **server-provided** name (Mac chat display name) or the raw handle | Default monogram |

The FCM background isolate uses the server-provided sender label or handle. This
keeps background push lightweight and avoids persisting an address-book cache for
push rendering.

## Set up Firebase push (optional)

Push uses a Firebase project **you own**.

1. In the Firebase console, create a project and add an **Android app**.
2. In the **Companion → Notifications**, enable Firebase and choose both files:
   `google-services.json` for the client runtime config and the service-account
   JSON for server-side sending.
3. On the phone, open **Settings → Notifications** in micaGO. When the client
   fetches the config it initializes Firebase at runtime and registers its token
   as an optional **Push Device**.
4. Use **Send test notification** in the Companion Notifications page to verify
   end-to-end delivery.

With Firebase off, the app uses WebSocket + delta sync, plus keep-alive if you
enabled it.

## Test FCM push end-to-end yourself (step by step)

Use this to verify your **own** Firebase push the whole way through, from the Mac
to a real notification on the phone.

**A. Create your Firebase project (once)**

1. Go to the [Firebase console](https://console.firebase.google.com/) → **Add
   project**. (Enabling Google Analytics is optional.)
2. In the project, **Add app → Android**. For the package name use the client's
   application id — `com.micago.message.mica_go` — and finish the wizard. Download
   the generated **`google-services.json`** (you keep this file; the app loads it
   at runtime).
3. **Project settings → Service accounts → Generate new private key.** This
   downloads a service-account **`.json`** — the server uses it to call FCM. Keep
   both files on the Mac.
4. Open **Google Cloud Console → IAM & Admin → IAM**, click **Grant access**, paste
   the service-account `client_email` as the new principal, and grant **Firebase
   Cloud Messaging API Admin**. The service account may not appear in the IAM
   list until after you grant it a role.

**B. Point the server at it (Companion)**

5. Open the Companion → **Notifications**. Turn **Firebase** on, choose
   **google-services.json**, choose the **service-account JSON** from step A3,
   and set the **Project ID** if you want to override the value inferred from the
   service account. The Companion validates both files and starts serving the
   client config at `GET /api/fcm/client`.
6. Make sure the server is **Running**.

**C. Register the phone as a push device**

7. On the phone, the app must be **paired** to this server (Sync Control / Paired
   Devices should show it). Open **Settings → Notifications** in the app.
8. The client fetches `/api/fcm/client`, initializes Firebase **at runtime**,
   requests the notification permission (Android 13+), and registers its FCM
   token. The Firebase / FCM card should show **Registered**.
9. Back in the Companion, **Notifications / Paired Devices** should now list the
   phone with push **enabled** and a token set.

**D. Fire a test and a real message**

10. In **Companion → Notifications**, tap **Send test notification**. A
   notification should arrive on every registered FCM device within a few seconds.
11. Now **background the app** (home button — don't force-quit yet) and send
    yourself an iMessage from another device/contact. You should get a native
    notification with the sender's name.
12. To test the hardest case, **force-quit** the app and send another message.
    With your own `google-services.json` present, the killed-app push still wakes
    a background isolate and shows the notification; tapping it opens the chat
    after a quick delta sync.

**E. If a step fails**

- Test push says *not configured*: Firebase isn't enabled on the server, or the
  phone hasn't registered a token yet (re-open Settings → Notifications).
- No notification on the phone but the server log shows the send: check the
  Android 13+ permission (see below) and that the phone has network.
- `Settings → Notifications → Notification diagnostics` (expand, then **Copy
  diagnostics**) shows Firebase configured?, token registered?, permission, and
  the last notification source — copy it to see exactly where the chain stops.

> Reliable **killed-app** push genuinely needs your own `google-services.json`.
> Without it, push covers foreground/backgrounded apps best-effort, and the
> keep-alive service (below) or delta catch-up fill the rest.

## Use keep-alive instead of (or alongside) Firebase

Turn on **Settings → Notifications → "Keep micaGO running in background"**. A
persistent notification appears and the connection is held open in the
background, so incoming messages raise local notifications with the same
formatting, contact name, tap routing and reply action as push — **no Firebase
required**. Expect higher battery use, and note that aggressive OEM battery
managers may still suspend the service; if alerts stop arriving in the
background, exempt micaGO from battery optimization in Android settings.

## Android 13+ notification permission

Android 13+ requires the `POST_NOTIFICATIONS` runtime permission. If it is
denied, **no** notifications appear regardless of Firebase/keep-alive. The
Notifications card detects this and shows a **"Notifications are turned off"**
warning with a **Turn on** action; if the system dialog no longer appears,
enable it under Android **Settings → Apps → micaGO → Notifications**.

## How to test

| Scenario | Expected |
| --- | --- |
| No Firebase, keep-alive **off**, app backgrounded | No background notification (delta catches up on resume). |
| No Firebase, keep-alive **on**, app backgrounded | A **local** notification per incoming message. |
| Firebase **on**, keep-alive off, app backgrounded | A local MessagingStyle notification shown from FCM data. |
| Firebase **on** and keep-alive **on** | Still **one** notification per message (deduped by id). |
| App **foregrounded**, chat open | **No** system notification (the UI shows it). |
| Tap a notification | Opens the correct chat. |
| Same chat, several messages | They **stack** into one MessagingStyle conversation, not separate notifications. |
| Contact has a photo | Avatar shows on the notification (keep-alive path); monogram otherwise. |
| Android 13+ permission denied | Detected; warning + "Turn on" shown. |

## Diagnostics

**Settings → Notifications → Notification diagnostics** (expand) shows, and can
copy (token/text-free): Firebase configured?, token registered?, keep-alive
enabled?, notification permission (granted/denied/unknown), the last notification
source (FCM / keep-alive), and the last direct-reply result.

# Enable Push Notifications (Firebase / FCM)

This guide walks you through enabling push notifications in micaGO using **your
own Firebase project**. Push is fully self-hosted, so notifications go through a
Firebase project that you create and control.

> **Push is optional.** While the Android app is open it receives messages in
> real time over WebSocket, and it catches up via delta sync whenever you reopen
> it. Firebase adds a best-effort way to **wake the app and show a notification**
> when Android allows background delivery. OEM battery policy can still delay or
> suppress delivery.

It takes about 10–15 minutes and uses only Firebase's free tier (Cloud
Messaging is free).

---

## What you'll do

1. Create your own Firebase project.
2. Add an Android app to it and download **`google-services.json`**.
3. Generate a **service-account key** (so your Mac can send pushes).
4. Point micaGO at both files.
5. Connect your phone and send a test push.

Prefer a shorter checklist with topic-by-topic pages? See the
[Firebase setup reference](overview.md).

You'll end up giving micaGO two files from *your* Firebase project:

| File | Who uses it | What it's for |
| --- | --- | --- |
| `google-services.json` | the Android app (served by your server) | lets the app register for push |
| service-account `*.json` | your Mac (the micaGO server) | lets your server send pushes |

These files stay part of your local Firebase setup — see [Privacy](#privacy).

---

## Prerequisites

- A Google account.
- micaGO Server running on your Mac via the micaGO Companion app.
- The micaGO Android app installed.

---

## Step 1 — Create a Firebase project

1. Go to the [Firebase Console](https://console.firebase.google.com).
2. Click **Add project**, give it any name (e.g. `my-micago`), and finish the
   wizard. You can disable Google Analytics — it isn't needed.

This project is yours. micaGO uses it through the two files below.

## Step 2 — Add an Android app and download `google-services.json`

1. In your project, open **Project settings** (the gear icon) → **General**.
2. Under **Your apps**, click **Add app** → the **Android** icon.
3. For **Android package name**, enter exactly:

   ```
   com.micago.message.mica_go
   ```

4. The SHA-1 and nickname fields are optional — leave them blank and continue.
5. Click **Download google-services.json** and save it somewhere stable on your
   Mac, e.g. `~/.micago/google-services.json`.

You can skip the remaining "add the SDK" wizard steps — micaGO already includes
the Firebase SDK and configures it at runtime from this file.

## Step 3 — Generate a service-account key

This lets your Mac authenticate to Firebase to *send* pushes.

1. In **Project settings** → **Service accounts**.
2. Click **Generate new private key** → **Generate key**.
3. A `*.json` file downloads. Save it on your Mac, e.g.
   `~/.micago/firebase-service-account.json`.
4. Open the JSON and note its `client_email`.
5. In **Google Cloud Console** → **IAM & Admin** → **IAM**, click **Grant access**.
6. Paste that `client_email` into **New principals**.
7. Grant **Firebase Cloud Messaging API Admin** and save.

It is normal if the service account only appears under **Service accounts** and
not in the IAM members list yet. Type the email manually when granting access.

> Keep this file private — it's a credential. Store it on your Mac, and avoid
> sharing it in email, git, chats, logs, or screenshots. micaGO stores the local
> path to it.

## Step 4 — Configure the micaGO server

There are two files. Both are selected in the Companion app.

### 4a. In the Companion app

1. Open the micaGO Companion and go to **Notifications**.
2. In **Firebase Self-Host (Android FCM)**:
   - Turn on **Notifications enabled**.
   - Turn on **Enable FCM delivery**.
   - Click **Choose google-services.json…** and select the file from Step 2.
   - Click **Choose service-account JSON…** and select the file from Step 3.
   - (Optional) Leave **Firebase project ID** blank — it's inferred from the
     JSON.
3. Click **Save**.

`google-services.json` contains public client identifiers. The service-account
JSON is the private key your Mac uses to send FCM. Keep both files on your Mac.

## Step 5 — Connect your phone

1. On the Mac, open **Dashboard → Create Connection** and either show the QR
   code or copy the connection JSON.
2. In the Android app, **scan the QR** or **paste the connection JSON**.

On connecting, the app automatically:

- fetches your Firebase client config from the server,
- initializes Firebase,
- registers its push token with your server.

`google-services.json` is loaded at runtime from *your* server, so the same app
build works with anyone's Firebase project.

## Step 6 — Verify it works

1. In the Companion, open **Advanced → Push Devices** and find your phone in the
   optional push registry.
2. The device card should show **push: enabled (fcm)** and **background:
   enabled**.
3. Open **Notifications** and tap **Send test notification**. You should get a
   notification on the phone within a few seconds.
4. Background the app, send yourself an iMessage, and confirm a notification
   appears; tapping it opens the right conversation.

## Privacy

- Push uses *your* Firebase project.
- Firebase is used for Android FCM push and, optionally, public-URL
  discovery if you enable Firestore URL sync).
- Contacts, phone numbers, bearer token, attachments, chat history, device
  registry, and sync rules stay in your micaGO setup.
- The service-account key never leaves your Mac. `google-services.json` contains
  only public client identifiers (project id, app id, API key, sender id) and is
  served to your paired devices over your authenticated connection.

## Troubleshooting

- **Device card shows "push: not configured"** — the app didn't get a Firebase
  config. Re-open Companion → **Notifications**, choose `google-services.json`,
  save, and reconnect the phone.
- **"config invalid (fcm)"** in Provider Status — the service-account JSON is
  missing or unreadable. Re-choose it in **Notifications → Firebase Self-Host**.
- **Send test notification fails** — confirm the phone is paired and shows **connected**, the
  package name in Firebase is exactly `com.micago.message.mica_go`, and the
  service account and `google-services.json` are from the **same** Firebase
  project.
- **No background notifications, but foreground works** — background delivery
  depends on FCM + Android's battery settings. Make sure the app isn't
  battery-restricted in Android Settings. Even if a wake is missed, the app
  catches up via delta sync the next time you open it.
- **Foreground duplicates** — when the app is open and connected, it uses the
  WebSocket and ignores the redundant push.

## Turning push off

- In **Notifications → Firebase Self-Host**, click **Clear Firebase config** or
  turn off **Enable FCM delivery**, then save.
- The app continues over WebSocket + delta sync.

---

### A note on automated setup

The manual steps above are the supported way to enable push. They remain fully
self-hosted and optional: you bring the Firebase project and keep control of it.

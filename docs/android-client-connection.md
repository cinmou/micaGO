# Android Client Connection

This guide covers connecting the **Android app** to your Mac server. The easiest
path is to **scan the pairing QR code** shown in the Mac app.

## What the Android client can do today

- **Pair by QR code** (or manual URL + token entry); the token is stored in
  Android's encrypted storage and kept out of logs.
- **Test the REST connection** and **connect the realtime WebSocket**.
- **Show the chat list** and open a **message thread** (history).
- **Send text and attachments** (with a sending → sent/failed state) over
  iMessage; SMS sending when you enable it on the Mac.
- **Display reactions, replies, effects, stickers, and media** — images,
  voice/audio, video, and files, with a full-screen media viewer.
- **Match local device contacts** (read-only, opt-in) to show names instead of
  raw phone numbers/emails.
- **Receive push notifications** (optional — requires your own Firebase project)
  and an opt-in keep-alive background mode.

## Limitations

- **Edit / Unsend / Delete** require the optional IMCore helper and your Mac
  granting it access; otherwise those actions are hidden.
- **Reliable notifications while the app is fully killed** work best with your own
  `google-services.json` and/or the keep-alive mode; otherwise messages still
  arrive over the socket + catch-up sync when the app is open.

## Step 1 — Install the app

If you have a debug build (APK):

1. Copy the APK to your Android device (or build and run it from a computer with
   Flutter installed).
2. On the device, allow installing from your file manager / browser if prompted
   ("Install unknown apps").
3. Open the APK and install it, then launch **micaGO**.

> A debug build is for testing only. Treat it like any pre‑release app.

## Step 2 — Pair with a QR code (recommended)

1. On the Mac, open **Connections → Client Setup**.
2. Choose the endpoint with the picker (**Auto** is usually right: it picks
   **Public** when reachable, otherwise **LAN**, otherwise **Local**).
3. Click **Show QR code**.
4. In the Android app, tap **Scan QR code** and point the camera at it.
5. Review the previewed server URL (token stays masked) and tap **Use this
   server**. The app tests the connection and goes to the chat list on success.

The QR encodes the selected **base URL**, **WebSocket URL**, and **token** — so
you don't type anything. Prefer the **Public** endpoint if you're pairing a
phone that will be used over mobile data.

## Step 2b — Or enter the connection manually

Pick the address that matches where your phone is:

- **Same Wi‑Fi as the Mac (LAN):**

  ```
  http://<Mac-LAN-IP>:<PORT>
  ```

  Find `<Mac-LAN-IP>` in the Mac app's connection list (or macOS System
  Settings → Network). The default `<PORT>` is `3000` — use whatever the Mac app
  shows.

- **Anywhere (public domain), after the Cloudflare setup:**

  ```
  https://micago.example.com
  ```

> ⚠️ **Use the Mac's LAN IP on the phone.** On Android, `127.0.0.1` means *the
> phone itself*. Use the Mac's LAN IP or your public domain.

## Step 3 — Enter your details

In the app's connection screen:

1. **Server URL** — the address from Step 2.
2. **Bearer token** — paste the token from the Mac app.
3. **WebSocket URL (optional)** — leave this blank. The app derives it
   automatically (see below). Only fill it in if your setup uses a different
   host for realtime.

> ⚠️ Keep your token private. Share screenshots of this screen only with the token
> hidden.

## Step 4 — Test the connection

Tap **Test connection**. The app will:

1. Check the server is alive (a no‑auth health check).
2. Check your token is accepted (an auth check).

A success message means both passed. Then tap **Save & continue** to go to the
home screen, where the app opens the WebSocket automatically.

## How the WebSocket URL is derived

If you leave the WebSocket field blank, the app builds it from your server URL:

- `http://…`  →  `ws://…`
- `https://…` →  `wss://…`
- it appends the `/ws` path.

Examples:

- `http://<Mac-LAN-IP>:<PORT>`  →  `ws://<Mac-LAN-IP>:<PORT>/ws`
- `https://micago.example.com`      →  `wss://micago.example.com/ws`

## Expected successful result

- **Health check passes** (server reachable).
- **Auth check passes** (token accepted).
- **WebSocket connected** — the status chip shows **Connected**.
- The **debug log shows received events** as activity happens on the Mac
  (for example when new Messages arrive).

## Common errors

| What you see | Likely cause | Fix |
| --- | --- | --- |
| **401 / token rejected** | Wrong or stale bearer token | Re‑copy the exact token from the Mac app and try again. |
| **Cannot reach host** | Wrong URL, server not running, or wrong network | Confirm the server is running, the URL/port match the Mac app, and the phone can reach that address. |
| **WebSocket connection failed** | Token query rejected, tunnel/proxy not passing WebSockets, or wrong scheme | Confirm REST works first; ensure `wss://` is used for HTTPS servers and the tunnel is running. |
| **LAN address times out** | Phone isn't on the same Wi‑Fi | Put the phone on the same network as the Mac, or use the public URL. |
| **Nothing loads with `127.0.0.1`** | Used loopback on the phone | Use the Mac's LAN IP or your public domain instead. |

If REST works while WebSocket fails, the
[Remote Access guide](remote-access-cloudflare.md) and
[Manual Test Flow](manual-test-flow.md) have more checks.

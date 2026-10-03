# Android Client Connection

This guide covers connecting the **Android app** to your Mac server. The easiest
path is to **scan the pairing QR code** shown in the Mac app.

## What the Android client can do today

- **Pair by QR code or pasted single-use connection JSON**; the device credential is stored in
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

## Step 2 — Pair

On the Mac, open Connections and create a new pairing code. Scan its QR in
Android or paste the connection JSON. The code expires after five minutes and
can be used once. The client tests encrypted LAN candidates before the optional
public HTTPS route, redeems the invitation, and stores its independent device
credential in Android secure storage. The certificate fingerprint in the QR
identifies the Mac on LAN; public routes use system certificate trust.

LAN defaults to `https://<Mac-LAN-IP>:3001` and `wss://<Mac-LAN-IP>:3001/ws`.
The actual TLS port is the configured server port plus one. HTTP on port 3000
is loopback-only for Companion and local proxies. Phone clients never fall back
to HTTP. Use the JSON to carry the certificate pin rather than entering a LAN
URL and a shared password manually.

Upgrade the Mac backend and clients together to 0.84, then pair again. Existing
chat caches and sync queues survive. Settings backups exclude device credentials;
a new installation must pair independently. Revoke a lost device in Companion
to reject further requests and close its realtime connections.

## Expected successful result

- **Health check passes** (server reachable).
- **Auth check passes** (token accepted).
- **WebSocket connected** — the status chip shows **Connected**.
- The **debug log shows received events** as activity happens on the Mac
  (for example when new Messages arrive).

## Common errors

| What you see | Likely cause | Fix |
| --- | --- | --- |
| **401 / token rejected** | Wrong or stale bearer token | Create a new pairing code on the Mac and pair again. |
| **Cannot reach host** | Wrong URL, server not running, or wrong network | Confirm the server is running, the URL/port match the Mac app, and the phone can reach that address. |
| **WebSocket connection failed** | Token query rejected, tunnel/proxy not passing WebSockets, or wrong scheme | Confirm REST works first; ensure `wss://` is used for HTTPS servers and the tunnel is running. |
| **LAN address times out** | Phone isn't on the same Wi‑Fi | Put the phone on the same network as the Mac, or use the public URL. |
| **Nothing loads with `127.0.0.1`** | Used loopback on the phone | Use the Mac's LAN IP or your public domain instead. |

If REST works while WebSocket fails, the
[Remote Access guide](remote-access-cloudflare.md) and
[Manual Test Flow](manual-test-flow.md) have more checks.

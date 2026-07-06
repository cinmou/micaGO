# Getting Started with micaGO

**English** · [简体中文](getting-started.zh-Hans.md) · [繁體中文](getting-started.zh-Hant.md)

This guide walks you through your first micaGO setup and the recommended order
to test each connection.

## What micaGO does (at this stage)

micaGO runs a small server on your Mac that exposes your Messages data to your
**own** devices over a private, token‑protected connection. A companion app on
the Mac starts/stops the server and shows you how to connect.

You can reach the Mac in three ways:

1. **This Mac (local)** — from the Mac itself.
2. **LAN (same Wi‑Fi)** — from another device on the same network.
3. **Public (remote)** — from anywhere, using your own domain and a tunnel you
   set up yourself (see
   [Remote Access with Cloudflare Tunnel](remote-access-cloudflare.md)).

There is no micaGO cloud. Your data stays between your Mac and your devices.

## What you need

- A **Mac signed in to Messages** (iMessage working in the Messages app).
- The **micaGO Mac app** (companion/server) installed and running.
- Required **macOS permissions** for the Mac app. If a permission is missing,
  the Mac app will tell you and link to the right Settings panel. In general the
  app needs permission to read the Messages database (Full Disk Access) and to
  control Messages for sending. Grant what the app asks for, then start the
  server again.
- An **Android device** for testing the mobile client (optional but recommended).

## The Mac app, card by card

Open the micaGO Mac app. The **Server** and **Connections** screens are
organized into a few cards:

- **Server Runtime** — Start / Stop / Restart, the running status, the address
  the server is **listening on**, and (collapsed) recent log output. The backend
  binary lives under an **Advanced** disclosure — you normally never touch it.
- **Server Bind Address** — choose who can reach the server:
  - **This Mac only** (`127.0.0.1:<PORT>`) — only apps on this Mac.
  - **Local network** (`0.0.0.0:<PORT>`) — devices on the same Wi‑Fi (adds LAN
    endpoints).
  - **Custom** — advanced host/port.
  Changing this shows **Restart required**; use **Save & Restart**. *(Remote
  access via Cloudflare Tunnel works even with “This Mac only”, because
  cloudflared runs on this Mac.)*
- **Connection Endpoints** — three sections, **Local / loopback**,
  **LAN / same Wi‑Fi**, and **Public / remote**, each with copy buttons. The
  Public section is where you paste and validate your remote URL.
- **Client Setup** (Pair Android) — pick an endpoint (Auto / Local / LAN /
  Public), then **Show QR code** or **Copy setup JSON** to pair a phone. The
  **bearer token** is shown masked with a Reveal/Copy action.

> ⚠️ **Keep your token private.** The bearer token is effectively a password.
> It stays masked by default — only reveal it when no one is watching, and keep it
> out of screenshots, logs, bug reports, or chats. If it leaks, generate a
> new token and re‑pair your devices.

## First connection options

- **This Mac / local** — `http://127.0.0.1:<PORT>`. Fastest way to confirm the
  server is alive. Note: `127.0.0.1` only works **on the Mac itself**, not from
  your phone.
- **LAN / same Wi‑Fi** — `http://<Mac-LAN-IP>:<PORT>`. Use this from a phone or
  laptop on the same network. Find `<Mac-LAN-IP>` in the Mac app's connection
  list, or in macOS System Settings → Network.
- **Public / remote domain** — `https://micago.example.com`. Use this from
  mobile data or any outside network after you complete the Cloudflare guide.

## Recommended path

Test connections in this order — each step builds on the previous one:

1. **Test the local server.** On the Mac, confirm the server is running and
   reachable at `http://127.0.0.1:<PORT>`.
2. **Test LAN.** From another device on the same Wi‑Fi, reach
   `http://<Mac-LAN-IP>:<PORT>` and confirm the token is accepted.
3. **Set up a remote URL** (optional). Follow
   [Remote Access with Cloudflare Tunnel](remote-access-cloudflare.md) to get
   `https://micago.example.com`, then in **Connection Endpoints → Public /
   remote** paste the URL, **Save**, and click **Validate Public URL**. When it
   reads **Reachable**, Public is ready for pairing.
4. **Pair the Android client.** In **Client Setup**, choose the endpoint
   (**Auto** picks Public when reachable, else LAN, else Local), then **Show QR
   code** and scan it from the Android app — or **Copy setup JSON**. See
   [Android Client Connection](android-client-connection.md).
5. **Verify the WebSocket.** In the Android app, confirm the realtime connection
   shows **Connected** and that the debug panel lists incoming events.

For an exact, copy‑paste checklist of all of the above, see the
[Manual Test Flow](manual-test-flow.md).

## What success looks like

- The server's health check responds without a token.
- Your token is accepted by the auth check.
- The Android app shows **Connected** for the WebSocket and logs events in the
  debug panel.

If something does not work, each guide has a Troubleshooting section, and the
[Manual Test Flow](manual-test-flow.md) helps you find which step failed.

# micaGO — User Documentation

**English** · [简体中文](index.zh-Hans.md) · [繁體中文](index.zh-Hant.md)

[← Project README](../README.md) · [Getting started](getting-started.md) · [CHANGELOG](../MicaGoServer/docs/CHANGELOG.md)

---

These guides help you set up the Mac app, connect from your phone, and optionally
reach your Mac from anywhere. micaGO lets your **own** devices talk to **your own**
Mac, with messages served between your Mac and the devices you connect.

---

## 📚 Guides

- **[Getting Started](getting-started.md)** — first-time setup: what you need,
  where to find your server URL and token, and the recommended order to test each
  connection.
- **[Android Client Connection](android-client-connection.md)** — pairing the
  Android app over LAN or a public URL, and what it supports.
- **[Remote Access with Cloudflare Tunnel](remote-access-cloudflare.md)** — reach
  your Mac from outside your home with your own domain. The tunnel is **external and
  optional**, and you manage it.
- **[Push Notifications](notifications-setup.md)** — optional self-hosted
  Firebase / FCM setup and troubleshooting for Android notifications.
- **[Firebase Setup Reference](setup/firebase/README.md)** — the same optional
  push setup as a focused checklist, with deeper step-by-step pages.
- **[Manual Test Flow](manual-test-flow.md)** — a copy-paste checklist you can run
  from zero to confirm local, LAN, public, and client connectivity.

---

## 🔐 Security notes

- Your **bearer token** is a password for your server. Anyone with your public URL
  **and** token can reach your Mac — keep it private.
- Keep your token out of screenshots, public logs, bug reports, chats, and issue
  trackers.
- Prefer **HTTPS** for anything leaving your home network (the Cloudflare guide
  gives you HTTPS automatically).
- If you think your token leaked, generate a new one in the Mac app and reconnect.

---

## 🧭 What's where

- The **Mac Companion** runs the server and shows your LAN + optional public
  connection details, paired devices, and diagnostics.
- The **Android app** pairs over LAN (same Wi‑Fi) or an optional public URL, syncs
  chats, sends text + attachments + voice (and SMS when you enable it), renders
  reactions/replies/effects/media/stickers/location, and optionally receives push.
- **Remote access** uses your own domain + Cloudflare Tunnel, or another tunnel
  you choose and manage.

> Software/design docs and the development history live in
> [`MicaGoServer/docs/`](../MicaGoServer/docs/README.md) — these `/docs` guides are
> for **using** micaGO.

See each guide for details, and the [root README](../README.md) for build
instructions and the full feature list.

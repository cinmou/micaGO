<p align="center">
  <img src="docs/assets/Server.png" alt="micaGOServer" width="120" />
</p>

<div align="center">

# micaGO

**English** · [简体中文](README.zh-Hans.md) · [繁體中文](README.zh-Hant.md)

**Your iMessage, your Mac, your devices.**

*A self-hosted iMessage bridge.*

*Built with ♥️ for everyone.*

[![Documentation](https://img.shields.io/badge/Documentation-0064E0?style=for-the-badge)](https://github.com/cinmou/micaGo/blob/main/docs/index.md)
[![Website](https://img.shields.io/badge/Website-007AFF?style=for-the-badge)](https://micago.cinmou.uk)
[![Getting started](https://img.shields.io/badge/Getting_started-0A1317?style=for-the-badge)](https://github.com/cinmou/micaGo/blob/main/docs/getting-started.md)
[![Security model](https://img.shields.io/badge/Security_model-31A24C?style=for-the-badge)](https://github.com/cinmou/micaGo#-security-model)
[![Remote access](https://img.shields.io/badge/Remote_access-5D6C7B?style=for-the-badge)](https://github.com/cinmou/micaGo/blob/main/docs/remote-access-cloudflare.md)
[![CHANGELOG](https://img.shields.io/badge/CHANGELOG-B89B5E?style=for-the-badge)](https://github.com/cinmou/micaGo/blob/main/MicaGoServer/docs/CHANGELOG.md)

</div>

---

## Overview

micaGO lets your **own** Android phone read and send your iMessages through your
**own** Mac. A small Go server on the Mac reads its local Messages database and
exposes a private, token‑protected API; a macOS menu‑bar **Companion** runs and
manages it; and a **Flutter Android app** pairs with it over your Wi‑Fi (or an
optional public URL you control). Your data only ever travels between **your** Mac
and **your** devices.

micaGO is still in testing. It reads macOS Messages internals and needs Full Disk
Access, so read the [security model](#security-model) and
[limitations](#limitations) before relying on it. micaGO is an independent
project.

## Screenshots

### Android

|  |  |  |
|:---:|:---:|:---:|
| <img src="docs/assets/Android%201.png" alt="Android conversation list" width="240" /> | <img src="docs/assets/Android%202.png" alt="Android settings" width="240" /> | <img src="docs/assets/Android%203.png" alt="Android message thread" width="240" /> |

### Android Tablet

|  |  |  |
|:---:|:---:|:---:|
| <img src="docs/assets/Pad%201.png" alt="Tablet split view" width="320" /> | <img src="docs/assets/Pad%202.png" alt="Tablet message thread" width="320" /> | <img src="docs/assets/Pad%203.png" alt="Tablet settings" width="320" /> |

### Mac Companion App

|  |  |  |
|:---:|:---:|:---:|
| <img src="docs/assets/Companion1.png" alt="Mac Companion dashboard" width="320" /> | <img src="docs/assets/Companion2.png" alt="Mac Companion pairing" width="320" /> | <img src="docs/assets/Companion3.png" alt="Mac Companion settings" width="320" /> |

---

## ✅ Requirements

- **Mac Companion:** macOS 13 or newer, signed in to iMessage, with Full Disk
  Access granted for Messages data.
- **Android client:** Android 6.0 or newer (API 23+). The client includes layouts
  for phones, tablets, and large screens.
- **Network:** LAN is recommended for first setup. Remote access is optional and
  requires your own public URL or tunnel.

---

## ✨ What you get

- **Self-hosted.** The bridge runs on your Mac. Optional push and remote access
  use services **you** own and configure.
- **Chats & messages.** Conversation list, threads, reactions/tapbacks, replies,
  send effects, stickers, **location / handwriting / Digital Touch**, and inline
  image/video media with a full‑screen viewer.
- **Send.** Text + attachments over iMessage, **voice messages**, and SMS when
  you turn it on (off by default, gated by a server setting).
- **Realtime + catch-up.** WebSocket events for live updates, plus a cursor
  **delta** sync that fills gaps after the app was closed.
- **LAN-first connectivity.** Multiple LAN routes are advertised; the client
  auto‑selects a reachable one and lets you pin it. An optional public URL (your
  own tunnel) works from anywhere.
- **Contacts matching.** On-device name resolution is opt-in and stays local to
  the device.
- **Notifications (optional).** Keep-alive and FCM both render through the
  client’s native Android MessagingStyle notification path. Prefer push? Point it
  at **your own** Firebase.

---

## 🧩 How it works

```
            ┌──────────────────────── your Mac ──────────────────────────┐
            │                                                            │
 Messages   │   chat.db ──► sync loop ──► relay.db ──► REST + WebSocket  │
 (iMessage) │      ▲                                         │           │
            │      │ AppleScript / optional IMCore helper    │           │
            │   ┌──┴───────────────┐                         │           │
            │   │  Mac Companion   │  runs & manages the server          │
            │   │  (menu‑bar app)  │                         │           │
            │   └──────────────────┘                         │           │
            └────────────────────────────────────────────────┼───────────┘
                                                             │
                         LAN (same Wi‑Fi)  ──or──  optional public URL (your tunnel)
                                                             │
                                                   ┌──────────▼──────────┐
                                                   │   Android client    │
                                                   │  (Flutter app)      │
                                                   └─────────────────────┘
```

- **Read path** — the server syncs `chat.db` one‑directionally into its own
  `relay.db`, then serves a small, stable REST + WebSocket API. The client pulls a
  cursor‑based **delta** for catch‑up and gets realtime events over the socket.
- **Send path** — text via AppleScript through Messages; attachments via multipart
  upload. Edit / Unsend / Delete use an optional bundled
  [IMCore helper](#-optional-features).
- **Pairing** — the Companion shows a QR code / connection JSON with the LAN/public
  candidates + a bearer token; the client scans or pastes it.

---

## 🔐 Security model

micaGO is **local‑first** and built so your data stays yours.

| Concern | How micaGO handles it |
| --- | --- |
| **Auth** | Every API call needs a server‑generated **bearer token** (`~/.micago/config.yaml`). Anyone with your URL **and** token can reach your Mac — treat it like a password. |
| **Network** | Default bind is your **LAN**. Public exposure is opt‑in and your responsibility; prefer HTTPS for anything leaving your network. |
| **Your data** | Messages are served from your Mac to paired devices. Contacts are matched on-device. |
| **Push** | If you enable FCM, payloads carry a small wake/preview for notification delivery. |
| **Private APIs** | The optional IMCore helper (edit/unsend/delete) is gated behind capability checks. |

In short, micaGO bridges your iMessage to your devices over a connection you
control. Message history remains anchored to the Messages data on your Mac.

---

## 🚀 Quick start

The easiest path is the **Companion**, which builds + launches the bundled server:

1. Open `MicaGoServer/micago-mac-companion/MicaGoCompanion.xcodeproj` in Xcode and
   run it (or build a release and launch it).
2. Grant **Full Disk Access** when prompted, then **Start** the server. It binds
   `0.0.0.0:3000` (LAN‑reachable) by default.
3. On the Companion's **Create Connection** card, show the QR code (or copy the
   connection JSON).
4. In the Android app, **Scan QR** or **Paste connection JSON** to pair — it
   connects over LAN automatically.

Prefer the command line? See [building each component](#-building-each-component).

---

## 🛠 Building each component

**Server** (`MicaGoServer/micago-server`)

```sh
cd MicaGoServer/micago-server
go build ./cmd/micago        # produces ./micago
./micago --version
go test ./...
go run ./cmd/micago          # generates ~/.micago/config.yaml + a token on first run
```

**Companion** (`MicaGoServer/micago-mac-companion`)

```sh
cd MicaGoServer/micago-mac-companion
xcodebuild -project MicaGoCompanion.xcodeproj -scheme MicaGoCompanion -configuration Debug build
```

> The Xcode build phase compiles the bundled `micago` backend **and** the
> `micago-imcore-helper` into the app's `Resources/`.

**Client** (`MicaGoFlutterClient`)

```sh
cd MicaGoFlutterClient
flutter pub get
flutter analyze
flutter test
flutter build apk --debug      # or: flutter run
```

---

## 🧰 Optional features

These features are optional and **off by default**.

- **Keep-alive service (Android).** The simple path, and how most people will run
  it: a foreground service holds the connection open and raises a local notification
  when a message lands. Default off, and OEM battery managers can still throttle it.
- **Firebase / FCM push.** Rather not keep a service running? Wire up **your own**
  Firebase project for background push. FCM is data-only; the
  client renders the same local MessagingStyle notification and then syncs the
  message over WebSocket or delta. See
  [`docs/setup/firebase/`](docs/setup/firebase/README.md).
- **Edit / Unsend / Delete (IMCore helper).** A small bundled helper that calls
  private macOS IMCore APIs.
  - *What it's for* — edit/unsend/delete a sent iMessage from the phone.
  - *Capability behavior* — if your Mac cannot grant IMCore access, the app reports
    *unsupported* and hides those actions.
- **Remote access.** Put your own reverse proxy / tunnel (e.g. Cloudflare Tunnel)
  in front of the server and set the **Public URL** in the Companion. See
  [`docs/remote-access-cloudflare.md`](docs/remote-access-cloudflare.md).

---

## 🗂 Repository layout

```
MicaGo/
├── MicaGoServer/
│   ├── micago-server/          # the Go relay server (the `micago` binary)
│   ├── micago-mac-companion/   # macOS SwiftUI menu‑bar Companion
│   └── docs/                   # software/design docs + CHANGELOG
├── MicaGoFlutterClient/        # the Flutter Android client
├── docs/                       # user guides (getting started, remote access, …)
└── README.md
```

> `Ref/` (if present locally) holds third-party reference projects used during
> development and is git-ignored.

## ⚠️ Limitations

- **macOS‑bound.** The server must run on a Mac signed in to iMessage, with Full
  Disk Access. It reads the live Messages database.
- **Edit/Unsend/Delete** depend on your Mac granting private‑API (IMCore) access;
  where unavailable, those actions are hidden.
- **Notifications while the app is killed** lean on the keep‑alive service, or on
  your own `google-services.json` if you prefer Firebase. Without either, alerts are
  best‑effort, and the socket plus delta sync still catch everything up on reopen.
- **Verified on Android only.** The Flutter client can in principle build for other
  platforms, but Android is the only one tested. The API is client‑agnostic by design.
- micaGO is an independent project. Use at your own risk.

---

## 🤝 Contributing

Issues and pull requests are welcome. Before opening a PR:

- **Server:** `go build ./... && go vet ./... && go test ./...`
- **Client:** `flutter analyze && flutter test`
- **Companion:** build the `MicaGoCompanion` scheme in Xcode.

Keep changes lightweight and dependency-free where possible; avoid logging or
committing bearer tokens or push tokens.

---

## 🙏 Acknowledgments

micaGO owes a lot to two open-source projects that already mapped the hard parts of
iMessage. We are grateful for their work.

- **[BlueBubbles](https://github.com/BlueBubblesApp)** — a mature iMessage bridge.
  Its handling of stickers, link previews, location, handwriting, and Digital Touch
  was our reference for classifying and rendering those message types.
- **[imsg](https://imsg.sh)** by Peter Steinberger — a terminal iMessage tool with a
  clean read of `chat.db` and the attachment / StickerCache layout, which guided our
  server's read path.

Both are independent projects.

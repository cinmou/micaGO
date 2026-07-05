# MicaGoServer v0.10.0 — macOS SwiftUI Companion App

## Goal

Provide a **native macOS control surface** for the Go relay server. This is a
local **server controller**, not a browser dashboard and not a chat client.

A WebUI/admin page was explicitly rejected: it would blur the line with the
future cross-platform chat client and make the product feel less native on the
Mac, where the server actually runs.

```
┌────────────────────────┐        launches / controls        ┌─────────────────────┐
│  micago-mac-companion   │ ─────────────────────────────────▶ │   micago (Go binary) │
│  (SwiftUI, this app)    │                                    │   = the relay server │
│                         │ ◀── HTTP: /api/server/status …  ── │                     │
└────────────────────────┘        reads local control API      └─────────────────────┘
            │                                                            │
            └── reads ~/.micago/config.yaml (addr + bearer token) ───────┘
```

The Go server remains the actual relay. The companion only (a) launches/stops
the server binary as a child process and (b) talks to its local HTTP control
API. They stay in separate folders and ship separately.

## Repository layout

```
MicaGoServer/
  micago-server/         # existing Go relay server
  micago-mac-companion/  # SwiftUI macOS controller (this spec)
  docs/
```

> Note: in this repository the project root is `MicaGoServer/`, so the server,
> companion, and docs are siblings under it (matching the intended
> `micago-server / micago-mac-companion / docs` structure).

## Non-goals

No chat UI, no WebUI/React/Vue/Electron, no Socket.IO, no Firebase, no cloud
bootstrap, no BlueBubbles compatibility, no private-API helpers. The companion
is also **not** intended for the App Store; it is a local dev/companion app for
direct distribution. It is therefore **not sandboxed** (it must read
`~/.micago/config.yaml` and launch a binary).

---

## Part 1 — Server-side support (v0.9)

The companion relies only on these read-only / control endpoints. All require
the bearer token except `GET /api/health`.

| Endpoint | Use by companion |
| --- | --- |
| `GET /api/health` | liveness probe (no auth) |
| `POST /api/auth/check` | confirm the token is accepted |
| `GET /api/server/info` | name, version, capability flags, provider list |
| `GET /api/server/status` | **new in v0.9** — runtime status + diagnostics |
| `GET /api/server/connections` | active authenticated WebSocket sessions |
| `GET /api/devices` | optional push-device registry |

### `GET /api/server/status` (new)

Read-only runtime status. **Never** returns the bearer token or any push
token. Example response:

```json
{
  "ok": true,
  "version": "0.9.0",
  "startedAt": 1717372800000,
  "uptimeSeconds": 1234,
  "address": {
    "listen": "127.0.0.1:3000",
    "baseUrl": "http://127.0.0.1:3000",
    "websocketUrl": "ws://127.0.0.1:3000/ws",
    "lan": ["192.168.1.20:3000"]
  },
  "store": "relaydb",
  "auth": { "enabled": true },
  "sync": {
    "loopEnabled": true,
    "intervalSeconds": 5,
    "lastSyncAt": 1717372805000,
    "lastMessageRowId": 4242
  },
  "notifications": {
    "enabled": false,
    "provider": "none",
    "preview": "sender",
    "providers": ["none", "webhook", "fcm", "hms", "harmony_push", "ntfy"],
    "implemented": ["none", "webhook"],
    "stub": ["fcm", "hms", "harmony_push", "ntfy"]
  },
  "devices": { "count": 2 },
  "websocket": { "clients": 1 },
  "permissions": {
    "fullDiskAccess": { "status": "ok", "detail": "reads ~/Library/Messages/chat.db; grant Full Disk Access…" },
    "attachments": { "status": "ok", "detail": "reads ~/Library/Messages/Attachments…" },
    "automation": { "status": "unknown", "detail": "Automation (AppleScript control of Messages) cannot be probed without sending…" }
  }
}
```

`permissions.*.status` is `ok` | `denied` | `unknown`. Full Disk Access and
Attachments are probed by attempting a read of the relevant path; Automation
cannot be probed without side effects, so it is always reported `unknown` with
guidance to verify in System Settings.

### How the companion finds and reads each thing

| Need | Source | Mechanism |
| --- | --- | --- |
| **Server address / port** | `~/.micago/config.yaml` → `server.addr`; confirmed by `address` in `/api/server/status` | `ConfigReader` parses the flat YAML (same approach as the smoke scripts) |
| **Connection endpoints (local/LAN/public)** | `GET /api/server/urls` (v0.11) | `APIClient`; local/LAN always present, public optional |
| **Bearer token** | `~/.micago/config.yaml` → `auth.token` | `ConfigReader`; the token is read locally and **never** fetched from the API |
| **Current server status** | `GET /api/server/status` (after `GET /api/health` + `POST /api/auth/check`) | `APIClient`, polled every ~3s while the window is open |
| **Paired devices** | `GET /api/server/connections` → `data[]` | active authenticated WebSocket sessions, not push registration |
| **Push devices** | `GET /api/devices` → `data[]` | optional notification registry; test action lives in Notifications |
| **Notification provider status** | `notifications` block of `/api/server/status` | shows enabled/provider/preview and implemented vs stub providers |
| **Permission diagnostics** | `permissions` block of `/api/server/status` | Full Disk Access, Attachments, Automation |

The server's `version` is advertised as `0.11.0`, the notification provider
fallback list now includes `harmony_push`, and `implemented` vs `stub` reflect
that only `none` and `webhook` actually deliver today.

---

## Part 2 — The companion app (v0.10)

### Structure

```
micago-mac-companion/
  MicaGoCompanion.xcodeproj/        # opens directly in Xcode
  MicaGoCompanion/
    MicaGoCompanionApp.swift        # @main, single window
    AppModel.swift                  # observable state + polling
    ContentView.swift               # all UI sections
    QRCode.swift                    # CoreImage pairing QR
    Models/StatusModels.swift       # Codable mirrors of the API
    Services/
      ConfigReader.swift            # reads ~/.micago/config.yaml
      APIClient.swift               # async calls to the local control API
      ServerController.swift        # launches/stops the Go binary (Process)
      LaunchAtLogin.swift           # SMAppService wrapper
    Assets.xcassets/
  README.md
```

The Xcode project uses a **file-system-synchronized group** (Xcode 16+), so new
files added to the `MicaGoCompanion/` folder are picked up automatically — no
`project.pbxproj` editing required.

### Features (mapped to requirements)

1. **Start / Stop / Restart** the Go server — `ServerController` runs the
   configured `micago` binary as a child `Process`, capturing stdout/stderr.
2. **Running status** — green/grey dot driven by `GET /api/health` +
   `/api/server/status`.
3. **Connection Endpoints** — a "Connection Endpoints" section showing Local,
   LAN, and the optional Public URL (with copy buttons). Backed by
   `GET /api/server/urls` (v0.11); see
   [`spec-v0.11.0-connection-endpoints.md`](spec-v0.11.0-connection-endpoints.md).
   Local and LAN are always-on derived endpoints; public is an optional extra,
   not a mode.
4. **Show / copy bearer token** — masked by default, reveal/copy buttons, plus
   a **pairing QR code** encoding `{baseUrl, websocketUrl, token}` for the
   **selected** endpoint (Local for this Mac, LAN for same-network, Public for
   remote) — a per-pairing choice, not a server mode.
5. **Paired devices** — active authenticated WebSocket sessions from
   `GET /api/server/connections`.
6. **Push devices** — optional notification registry from `GET /api/devices`.
7. **Notification provider status** — enabled/provider/preview + implemented vs
   stub providers.
8. **Permission diagnostics** — Full Disk Access, Attachments, Automation, with
   color-coded status and remediation hints.
9. **Launch at Login** — a conservative `SMAppService.mainApp` toggle
   (macOS 13+), with a visible status string and graceful error handling.
9. **No chat UI** — this app is only the Mac server controller.

### Server binary path

The companion launches a **prebuilt** `micago` binary (it does not embed or
`go run` the server). Default path:

```
~/.micago/bin/micago
```

Build it there once:

```bash
cd MicaGoServer/micago-server
go build -o ~/.micago/bin/micago ./cmd/micago
```

The path is editable in the UI (and via a file picker) and persisted in
`UserDefaults`.

---

## Building & running in Xcode

1. `open MicaGoServer/micago-mac-companion/MicaGoCompanion.xcodeproj`
2. Select the **MicaGoCompanion** scheme, **My Mac** destination.
3. For local runs, set Signing to **Sign to Run Locally** (or your personal
   team). The project builds unsigned from the command line with
   `CODE_SIGNING_ALLOWED=NO`.
4. Press **Run**.

Command-line build used to validate this project:

```bash
cd MicaGoServer/micago-mac-companion
xcodebuild -project MicaGoCompanion.xcodeproj -scheme MicaGoCompanion \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Deployment target: macOS 13.0. Bundle id: `com.micago.companion`.

---

## Manual test steps

**Pre-req:** build the server binary to `~/.micago/bin/micago` (see above). The
first server launch creates `~/.micago/config.yaml` with a random token.

1. **Open & build** the Xcode project; confirm it builds and the window opens
   with the sections (Server, Connection Endpoints, Token, Paired Devices,
   Push Devices, Notifications, Diagnostics, Launch at Login, Server Log).
2. **Binary detection** — the path row shows a green seal when
   `~/.micago/bin/micago` exists; otherwise an orange warning. Use **Choose…**
   to point at another binary if needed.
3. **Start** — click Start. The dot turns green within a few seconds, the
   version shows `0.11.0`, and the Server Log shows `listening on …`.
4. **Connection Endpoints** — Local shows `http://127.0.0.1:3000` (+ `ws://…/ws`);
   LAN shows address(es) when bound to `0.0.0.0`, otherwise a loopback-only note.
   Copy buttons place the value on the clipboard. Optionally set a Public URL,
   click **Save**, then **Validate Public URL** and confirm the reachability dot.
5. **Token** — masked by default. **Reveal** shows the full token; **Copy**
   copies it; it matches `auth.token` in `~/.micago/config.yaml`. Expand
   **Pairing QR code**, pick an endpoint (Local/LAN/Public), and confirm the QR
   regenerates for the selected endpoint.
6. **Devices** — register a device against the server (e.g. run
   `zsh scripts/smoke-v0.7-devices.sh`), then **Refresh**; the device appears
   with its platform and push provider.
7. **Notifications** — confirm provider/preview and that `implemented` lists
   `none, webhook` while `stub` lists the rest.
8. **Diagnostics** — Full Disk Access shows `ok` when the terminal/app has FDA
   (otherwise `denied`); Automation shows `unknown` with guidance.
9. **Stop / Restart** — Stop turns the dot grey and logs the exit; Restart
   relaunches and the dot returns to green.
10. **Launch at Login** — toggle on; the status reads `enabled` (or
    `requires approval` — then approve under System Settings → General → Login
    Items). Toggle off and confirm it returns to `not registered`. This is best
    verified with a built app copied to `/Applications`; from a raw Xcode debug
    build macOS may report `requires approval`.

### Notes on permissions

- **Full Disk Access** is needed by the **server** process (and therefore by
  whatever launches it). When run from Xcode/Terminal, grant FDA to that host
  app, or run a built, signed companion app and grant FDA to it.
- **Automation** prompts appear when the server first sends an iMessage via
  AppleScript; it cannot be pre-probed, hence the `unknown` status.

## Out of scope / future

- Bundling/auto-discovering the server binary inside the app.
- Menu-bar (`LSUIElement`) mode.
- Pairing flow on the client side that consumes the QR payload.
- Implementing the stubbed push providers (tracked separately).

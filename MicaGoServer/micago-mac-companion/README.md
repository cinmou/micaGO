# micaGO Mac Companion

A native **macOS SwiftUI controller** for the micaGO Go relay. It launches
and monitors the local `micago` server binary and talks to its local control
API. It is **not** a chat client and **not** a web dashboard.

Full design and manual test steps:
[`../docs/spec-v0.10.0-mac-companion.md`](../docs/spec-v0.10.0-mac-companion.md).

## Open in Xcode

```bash
open MicaGoCompanion.xcodeproj
```

Select the **MicaGoCompanion** scheme and **My Mac**, set Signing to
**Sign to Run Locally** (local dev), and Run. Deployment target: macOS 13.

Command-line build (unsigned):

```bash
xcodebuild -project MicaGoCompanion.xcodeproj -scheme MicaGoCompanion \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

## Server binary it controls

The companion launches a prebuilt server binary (default `~/.micago/bin/micago`):

```bash
cd ../micago-server
scripts/update-backend.sh
```

The script builds the backend with version/commit/build-time stamps, installs it
to `~/.micago/bin/micago`, and sets the micaGO Companion backend-path override so local
development runs the newly built binary instead of an older bundled copy. The
path is still editable in-app and persisted. The first server run creates
`~/.micago/config.yaml` with the bearer token the companion reads.

## What it shows

Start/stop/restart · running status · **Connection Endpoints** (local, LAN, and
an optional public URL with validate/save) · bearer token (reveal/copy + pairing
QR for a selected endpoint) · registered devices · notification provider status ·
permission diagnostics (Full Disk Access, Automation) · optional IMCore helper
install/status · Launch at Login.

Local and LAN endpoints are always active; the public URL is an optional extra,
not a mode. See [`../docs/spec-v0.11.0-connection-endpoints.md`](../docs/spec-v0.11.0-connection-endpoints.md).

## Not included (by design)

No chat UI, no WebUI, no Socket.IO, no micaGO cloud bootstrap, and no
BlueBubbles compatibility. Firebase/FCM is optional and user-owned. The IMCore
helper is optional, private-API based, and only enabled when the helper and macOS
environment report support. Not sandboxed and not intended for the App Store —
it is a local companion/control app.

# v0.11.2 — Companion Runtime & Deployment

Status: **Planned** (spec only; no code in this pass). Companion-side follow-up
to [`spec-v0.10.1-swiftui-companion-redesign.md`](spec-v0.10.1-swiftui-companion-redesign.md)
and [`spec-v0.11.x-server-reliability.md`](spec-v0.11.x-server-reliability.md).

## Goal

Make the SwiftUI companion a real **Mac service controller**: it ships the Go
backend inside the app, owns its lifecycle (start/stop/restart, crash recovery,
auto-restart, launch-at-login, auto-start, silent launch), exposes a **menu-bar
status item**, and surfaces permission failures (especially Full Disk Access)
clearly. The Go server stays the relay; the companion is the product surface.

## BlueBubbles reference inspected

- `packages/server/appResources/macos/daemons/{ngrok,zrok,cloudflare}/` — the
  pattern of **bundling helper binaries inside the app bundle** (we apply it to
  the `micago` binary, not tunnels).
- `packages/server/src/trays/AppTray.ts` — menu-bar item with labeled actions
  (version, Open, Restart, Close, server address, connection count, Caffeinated
  status). We adapt the **concept**, not the Electron code.
- `services/caffeinateService/index.ts` — keep-awake (already mirrored in the
  companion's `RuntimeMonitor`).

## Non-goals

No Firebase (v0.12); no sync filtering (v0.11.3); no scheduled sending (v0.13);
no BlueBubbles Electron/WebUI; no Socket.IO; no bundled tunnel management
(Cloudflare/ngrok/Tailscale); no private-API helpers.

## Design

### 1. Bundling the Go backend binary

- Build `micago` (universal `arm64`+`x86_64` via `lipo`, or arch-native) and
  copy it into the app bundle at **`MicaGoCompanion.app/Contents/Resources/micago`**
  via an Xcode **Copy Files (Resources)** build phase or a pre-build script that
  consumes a checked-in/produced binary.
- At runtime the companion resolves the backend in this order:
  1. **Bundled** binary: `Bundle.main.url(forResource: "micago", withExtension: nil)`.
  2. A user-chosen path (existing `ServerController.binaryPath`, persisted).
  3. The legacy default `~/.micago/bin/micago`.
- The bundled binary is the default; the path picker remains for development
  override. The binary must be executable (`chmod +x` preserved by the copy
  phase) and, for distribution, **code-signed** as part of the app (hardened
  runtime). Document a `scripts/build-universal.sh` to produce the binary the
  copy phase consumes (script lives in `micago-server/scripts/`, build-only).

### 2. Backend binary version detection

- The Go binary gains a `--version` flag (server-side change is allowed in the
  v0.11.2 implementation pass; it prints `serverVersion` and exits 0). The
  companion runs `micago --version` once on launch to display the **bundled
  backend version** even before the server is started.
- After the server is running, the companion cross-checks against
  `GET /api/server/info`/`status` `version`; a mismatch (e.g. an old running
  process vs a newer bundled binary) shows a "restart to update backend" hint.

### 3. Companion-owned start / stop / restart

- Keep the existing `ServerController` (child `Process`, captured stdout/stderr,
  `terminationHandler`). Extend it to:
  - track **launch state**: `stopped | starting | running | crashed | stopping`;
  - record the **last exit**: termination status + signal + a tail of stderr;
  - expose `start()/stop()/restart()` (restart = stop, wait for exit, start).
- "Running" for the UI is the AND of *process alive* and *health reachable*
  (`GET /api/health`), so a process that started but failed to bind/serve shows
  as `crashed`/`starting`, not `running`.

### 4. Crash detection & exit-reason display

- On `terminationHandler`, classify the exit:
  - clean stop (we asked) → `stopped`;
  - non-zero exit / signal while we expected it running → `crashed`.
- Surface a clear **exit reason** in the UI (Dashboard banner + Logs): exit
  code, signal, and the captured stderr tail. Map known fatal causes to friendly
  messages (see §11 FDA).

### 5. Auto-restart with backoff

- Optional, user-toggled "**Keep server running**". When the process crashes
  (not a user stop), auto-restart with **exponential backoff**: 1s, 2s, 5s, 15s,
  30s, capped at 60s; reset the backoff after the server stays healthy ≥ 60s.
- Stop auto-restarting after **N consecutive crashes** (e.g. 5) and show a
  persistent error ("server keeps crashing — see Logs"), to avoid a restart
  storm. Never auto-restart a **permission failure** (FDA) — that won't fix
  itself; show the remediation banner instead.

### 6. Launch at Login

- Keep the existing `SMAppService.mainApp` toggle. Document that it is best
  validated from a built, signed app in `/Applications` (a raw Xcode debug build
  may report `requires approval`).

### 7. Auto-start server when the companion launches

- User setting "**Start server when the app opens**" (default off until the
  binary + FDA are confirmed; suggested on after first successful run).
- On launch, if enabled and the binary exists and FDA looks granted, start the
  server automatically.

### 8. Silent launch / hide window at launch

- User setting "**Launch hidden (menu bar only)**". When combined with
  Launch-at-Login + auto-start, the app starts at login, runs the server, and
  shows **no window** — only the menu-bar item. The main window opens on demand
  (menu-bar "Open Dashboard" or Dock click).
- Implementation note: use `NSApplication` activation policy
  (`.accessory` when hidden, `.regular` when a window is shown) **or** an
  `LSUIElement`-style behavior toggled at runtime; do **not** hard-code
  `LSUIElement` in Info.plist (that would permanently remove the Dock icon).
  The default remains a normal windowed app.

### 9. Menu-bar status item

- A `MenuBarExtra` (SwiftUI, macOS 13+) showing a status glyph that reflects
  reachable/stopped/crashed (e.g. filled/hollow/exclamation).
- The menu-bar item coexists with the main window; it is the always-available
  control surface when the window is hidden.

### 10. Menu-bar actions

- **Open Dashboard** — show/focus the main window (switch activation policy to
  `.regular`).
- **Start Server** / **Stop Server** — enabled per current state.
- **Open Messages** — `RuntimeMonitor.openMessages()`.
- **Keep Awake** — toggle (reflects `RuntimeMonitor.keepAwakeActive`).
- **Quit** — terminate the companion; **stop the child server first** (the
  `caffeinate -w <pid>` child already auto-exits, and the server child is
  terminated on quit so we don't orphan it).
- Plus non-interactive status labels (version, reachable, endpoint count) mirror
  the BlueBubbles tray concept.

### 11. Surfacing Full Disk Access failure clearly

- Today a denied FDA makes the Go server log `open chat.db: operation not
  permitted` and exit. The companion must not show only that raw string.
- Detection (companion-side, no new API required): when the process exits
  quickly with stderr containing `operation not permitted` / `unable to open
  database file` for the chat.db path, classify as **`fda_denied`** and show a
  prominent banner: "Full Disk Access is required. Grant it to micaGO Companion
  in System Settings → Privacy & Security → Full Disk Access, then start the
  server." with a button that opens that pane
  (`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`).
- Optional server hint (allowed in implementation): the Go binary may print a
  single clearer line and exit with a **distinct exit code** for the FDA case so
  the companion classifies deterministically rather than by string match. The
  `/api/server/status` `permissions.fullDiskAccess` probe remains the signal once
  the server *is* running.

### 12. Preserving the local / LAN / public endpoint model

- Runtime/deployment changes are orthogonal to the endpoint model from
  [`spec-v0.11.0-connection-endpoints.md`](spec-v0.11.0-connection-endpoints.md):
  local + LAN remain always-derived; public stays an optional extra. The
  companion's Connections surface is unchanged by this milestone.

## Security & privacy boundaries

- The bundled binary is launched **locally** only; no elevated privileges, no
  daemon installed outside the app (Launch-at-Login uses `SMAppService.mainApp`,
  not a privileged helper).
- The companion never transmits the bearer token or push tokens anywhere; logs
  shown in the UI must **redact** any `Authorization: Bearer …` lines captured
  from stdout (the server should not print the token, but the companion redacts
  defensively).
- Auto-restart/keep-running is local supervision only; no telemetry.

## Implementation slices

1. **Bundle + resolve binary** + `--version` (server flag) + show bundled
   backend version.
2. **Lifecycle hardening**: launch-state machine, exit classification, exit-reason
   UI (Dashboard banner + Logs), FDA detection + remediation banner.
3. **Auto-restart with backoff** + "Keep server running" toggle (skip on FDA).
4. **Menu-bar item** (`MenuBarExtra`) + actions; coexist with the window.
5. **Auto-start** + **silent/hidden launch** + activation-policy switching; pair
   with Launch-at-Login.
6. Polish: redaction, settings persistence, empty/disconnected states.

## Manual test checklist

1. Fresh build: bundled `micago` is found without choosing a path; bundled
   version shows before starting.
2. Start from the window and from the menu bar; status reaches "Running" only
   after `/api/health` is reachable.
3. Kill the server process externally → companion shows **crashed** with exit
   reason; with auto-restart on, it comes back with visible backoff; after 5
   rapid crashes it stops and shows a persistent error.
4. Revoke Full Disk Access → starting shows the **FDA remediation banner**
   (not raw "operation not permitted"); the button opens the right Settings pane;
   auto-restart does **not** loop on this.
5. Launch-at-Login on + auto-start on + launch-hidden on → after re-login the app
   runs the server with **no window**, only the menu-bar item; "Open Dashboard"
   reveals the window.
6. Quit from the menu bar → the child server process exits (no orphan
   `micago`/`caffeinate`).
7. Endpoints unaffected: local/LAN/public still shown per the connection model.
8. Logs never contain a bearer token; build: `xcodebuild … CODE_SIGNING_ALLOWED=NO build`
   succeeds.

---

## v0.11.2.1 — Polish follow-up: Hide Dock icon / menu-bar-only mode

Status: **Planned** (small polish on top of the shipped v0.11.2 runtime work; not
yet implemented). This extends the existing silent-launch / menu-bar surface, so
it lives here rather than in v0.11.3 Sync Control.

### Goal

Let the user run micaGO Companion as a **menu-bar-only** app with **no Dock
icon**, while keeping the full Dashboard reachable on demand. Distinct from
**Launch hidden** (which only controls whether a window opens *at launch*): this
setting controls the **Dock presence while running**.

### Behavior

1. New setting (Advanced): **"Hide Dock icon when running in menu bar"**
   (`hideDockIcon`, persisted in `UserDefaults`, default off).
2. When enabled, the app runs as an **accessory** (`NSApp.setActivationPolicy(.accessory)`)
   so it does not appear in the Dock or the ⌘-Tab switcher.
3. The **menu-bar item remains visible** at all times (it is independent of
   activation policy).
4. **Open Dashboard** (menu bar) must always restore/show the main window:
   set `.regular`, `NSApp.activate(ignoringOtherApps: true)`, then
   `openWindow(id: "dashboard")`.
5. When the Dashboard window is **closed again**, if `hideDockIcon` is still on,
   the app returns to **`.accessory`** (menu-bar-only). Detect window close via
   an `NSWindow.willCloseNotification` observer, then re-apply `.accessory` if no
   other regular windows remain.
6. **Quit** from the menu bar still quits the app and stops the
   companion-managed backend cleanly (`backend.shutdownForQuit()` →
   `NSApp.terminate`).

### Activation-policy rules (single source of truth)

A small helper centralizes policy so the inputs don't fight each other:

- Effective policy = `.accessory` when `hideDockIcon` is on **and** no dashboard
  window is currently visible; otherwise `.regular`.
- `launchHidden` (existing) only affects whether a window is opened at launch; on
  a hidden launch with `hideDockIcon` on, the app starts as `.accessory`.
- Showing the Dashboard always forces `.regular` first (so the window can take
  focus), then re-evaluates on close.

### Must not break

silent launch, Launch at Login, auto-start server, auto-restart (backoff),
Keep Awake, external/unmanaged server detection, Dashboard/Connections — all
remain driven by the AppDelegate bootstrap + shared controllers (independent of
activation policy and window presence).

### Implementation notes (when approved)

- Add `hideDockIcon` to the settings store (alongside `autoStart`,
  `autoRestart`, `launchHidden`).
- Centralize policy in one `applyActivationPolicy()` called at launch, on the
  setting's `onChange`, after `openWindow`, and on dashboard-window close.
- Toggling the setting **off** must restore `.regular` immediately so the Dock
  icon reappears without a relaunch.
- Re-applying `.accessory` on window close must not terminate the app; assert
  `applicationShouldTerminateAfterLastWindowClosed` returns `false`.

### Manual test checklist (v0.11.2.1)

1. Enable "Hide Dock icon": the Dock icon disappears, the menu-bar item stays.
2. Open Dashboard from the menu bar → window appears and is focusable; Dock icon
   returns while the window is open.
3. Close the Dashboard window → with the setting on, Dock icon disappears again;
   menu bar still works.
4. Toggle the setting off while menu-bar-only → Dock icon reappears immediately.
5. Quit from the menu bar → app quits; no orphaned `micago` backend.
6. Regression: silent launch, Launch at Login, auto-start, auto-restart, Keep
   Awake, external-server detection, and Dashboard/Connections all still work.

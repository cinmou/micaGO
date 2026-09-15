# micaGO Windows

Native Windows client for a **micaGO** relay server, built with C#, .NET 10,
WinUI 3, and Windows App SDK 2.2. Two-pane Fluent chat UI (Mica backdrop,
Windows 11 settings-card styling), feature parity tracked against the Flutter
client.

Versions are kept in lockstep with the Flutter client, Go server, and macOS
Companion. Solution entry point: `micaGO.Windows.sln`.

> **Status: functional, still pre-release.** The client pairs, syncs, and chats
> against a real server, but several recent passes were authored on macOS and
> are still awaiting a Windows build/verification run, MSIX packaging has not
> started, and ARM64/Release configurations are unverified. The authoritative
> per-module status (including what "code complete, pending Windows
> verification" currently covers) is
> [docs/IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md).

## What it does today

- **Pairing & connection** — paste the Companion's connection JSON (v1/v2/v3
  payloads); all LAN candidates are probed in parallel (health + auth) and the
  fastest wins, with public-URL fallback. The bearer token is stored in
  **Windows Credential Manager** (never in config files); the rest of the
  profile lives in `%LOCALAPPDATA%\micaGO\connection-profile.json`. Saved
  pairings restore silently on launch — the dedicated pairing window
  (`ConnectionWindow`) only appears when restore fails or after a disconnect.
- **Chats & threads** — real `/api/chats` with search, contact-name/avatar
  resolution, multi-route contact merging (with a per-contact opt-out), local
  pin sorting, and watermark-derived unread dots that survive restarts.
  Messages are cache-first with 50-row paging; snapshots merge with live rows
  (`MessageSemantics.MergeSnapshot`) instead of replacing them, so realtime
  arrivals never flicker out.
- **Sending** — optimistic text bubbles with temp-GUID reconciliation and a
  stable presentation key (no re-animation on confirm); multi-file attachment
  sends with per-item progress, cancel, retry, and restart recovery; **voice
  messages** (MediaCapture → m4a).
- **Realtime + catch-up** — WebSocket with the token in the `Authorization`
  header and reconnect backoff; `message:*` frames are applied directly (read
  receipts/edits update live) and also trigger cursor-based delta catch-up
  persisted in SQLite (WAL).
- **Message rendering** — deterministic-bind `MessageBubble` (recycling-safe):
  media always renders bubble-less above the text bubble, reactions, replies
  with jump-to-source, URL preview cards, location cards (open in Maps),
  interactive-app/balloon cards, send effects (bubble + emoji particle screen
  effects, Invisible Ink cover), big-emoji and sticker handling, and **Twemoji
  flag emoji** (Windows has no flag glyphs; rendered via `RichTextBlock` —
  WinUI `TextBlock.Inlines` cannot host `InlineUIContainer`).
- **Media** — image viewer with zoom and prev/next, audio/video playback with
  an HEVC `playable` transcode fallback, save/open-with, on-disk media cache,
  and a details media grid.
- **Multi-select** — forward (re-uploads from the media cache under original
  names) and hide (`hidden_messages` tombstones that re-sync cannot resurrect).
- **Notifications & tray** — AppNotification per chat, click-through to the
  conversation, close-to-tray with a recent-contacts tray menu.
- **Settings** — General / Appearance / Contacts / Storage / About; theme,
  Twemoji flags toggle, chat background, bubble color (follow system accent or
  custom), vCard contact import, `.micagobak` settings backup/restore (the
  token is in Credential Manager and never enters the backup), offline test
  contact, and a read-only update check against GitHub releases. Localized in
  English, Simplified Chinese, and Traditional Chinese.

## Not done yet

MSIX packaging (currently unpackaged, self-contained), ARM64 and Release
verification, light/high-contrast theme verification, background transfers,
and the audit items listed at the bottom of
[IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md).

## Build

Requirements: Windows 11 (Windows 10 1809 minimum, but Mica renders only on
11), Visual Studio 2026 (or latest 2022) with the WinUI application
development workload, .NET 10 SDK, Developer Mode enabled.

```powershell
dotnet restore .\micaGO.Windows.sln
dotnet build .\micaGO.Windows.sln -c Debug -p:Platform=x64
```

Or open `micaGO.Windows.sln`, set `micaGO.App` as startup, select
`Debug | x64` (not ARM64 first), rebuild, F5.

Create the tested portable archive with `scripts/package-release-x64.ps1`.
After installing Inno Setup 7, `scripts/build-installer-x64.ps1` produces the
single-file `artifacts/micaGO-Setup-x64.exe` installer from that same archive.
The installer defaults to a per-user installation, adds a Start menu shortcut,
offers an optional desktop shortcut, supports in-place upgrades and registers a
normal Windows uninstaller. Public releases should Authenticode-sign the app
and installer, or use a Store-distributed MSIX for Microsoft-managed signing.

Core contract tests (no WinUI, no third-party test framework — plain
`dotnet run`, exit code 0 on success):

```powershell
dotnet run --project .\tests\micaGO.Core.ContractTests\micaGO.Core.ContractTests.csproj
```

## Project layout

```
src/
  micaGO.Core/            # pure logic: pairing, routing, message semantics (contract-tested)
  micaGO.Infrastructure/  # SQLite cache, API client, credential storage, backup, voice
  micaGO.App/             # WinUI 3 app: windows, ShellPage, MessageBubble, styles, Twemoji assets
tests/
  micaGO.Core.ContractTests/
docs/
  WINDOWS_FIRST_BUILD.md  # environment + first build/verification steps
  CONNECTION_PROTOCOL.md  # pairing JSON + credential security
  ARCHITECTURE.md         # code structure
  IMPLEMENTATION_STATUS.md# per-module status — the source of truth
```

## Technical choices

- Per-Monitor V2 DPI awareness; initial and minimum window sizes scale with
  the active display.
- Unpackaged, self-contained distribution for now; MSIX (and the Credential
  Manager → Credential Locker migration decision) comes after the connection
  path is fully verified.
- Design reference: the Flutter client's two-pane layout, with Unigram used
  only as a visual-density/Fluent-state reference — no GPL source, XAML, or
  assets are copied. Twemoji graphics are CC-BY 4.0 (see
  `THIRD-PARTY-NOTICES.md`).

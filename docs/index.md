# micaGO documentation

**English** · [简体中文](index.zh-Hans.md) · [繁體中文](index.zh-Hant.md) · [Project README](../README.md)

For installation, start with Getting Started. For code changes, read the architecture and only the feature/platform documents relevant to the task. Engineering documents are maintained in Chinese; identifiers and commands keep their original spelling.

## Install and use

| Task | Guide |
| --- | --- |
| Install, authorize and pair the first device | [Getting Started](getting-started.md) |
| Connect Android or Linux | [Client connection](android-client-connection.md) |
| Connect away from home | [Cloudflare Tunnel](remote-access-cloudflare.md) |
| Enable optional Android push | [Firebase setup](setup/firebase/README.md), [troubleshooting](setup/firebase/troubleshooting.md) |
| Verify actual device behavior | [Manual checks](manual-test-flow.md) |

## Development

| Topic | Document |
| --- | --- |
| Components, data flow and ownership | [Architecture](ARCHITECTURE.md) |
| Build, test, package and release | [Development](DEVELOPMENT.md) |
| Where to find current endpoints and models | [API navigation](reference/api.md) |
| Reasons behind important choices | [Decisions](decisions/README.md) |

## Feature behavior

- [Connection](features/connection.md): pairing, credentials, TLS, routes and revocation.
- [Messaging](features/messaging.md): send confirmation, history, identity, contacts and hiding.
- [Unread](features/unread.md): read positions, manual unread, merged routes and notification actions.
- [Media](features/media.md): uploads, previews, playback and caches.
- [Notifications](features/notifications.md): realtime, FCM, avatars, background actions and privacy.

## Platforms

- [Flutter](platforms/flutter.md): Android/Linux, lifecycle, shared UI and settings backups.
- [Mac](platforms/macos.md): windows, processes, tunnels, permissions and updates.
- [Windows](platforms/windows.md): WinUI, stable rows, contacts, notifications and packaging.

## Maintaining these documents

Feature pages describe current behavior. Decisions explain why. Unconfirmed proposals do not belong in current behavior. Create a plan only when work needs persistent task context; remove the process notes after extracting useful rules.

Old specifications and session records are available in Git history. Version changes are listed in [Releases](https://github.com/cinmou/micaGO/releases). Neither replaces current behavior or proves current validation.

When documentation and implementation disagree, check the code, tests and user requirements before changing either. Update the existing document instead of adding another summary.

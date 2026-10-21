<p align="center"><img src="docs/assets/Server.png" alt="micaGO" width="120" /></p>

# micaGO

[English](README.md) · [简体中文](README.zh-Hans.md) · [繁體中文](README.zh-Hant.md)

**Your iMessage, your Mac, your devices.**

micaGO connects Android, Linux and Windows clients to Messages on your Mac. A Go backend reads Messages, and a native Mac Companion manages pairing and server settings. Windows uses an independent WinUI app.

[Download](https://github.com/cinmou/micaGO/releases) · [Getting started](docs/getting-started.md) · [Documentation](docs/index.md) · [Website](https://micago.cinmou.uk)

## Screenshots

### Android

|  |  |  |
|:---:|:---:|:---:|
| <img src="docs/assets/Android%201.png" alt="Android conversation list" width="240" /> | <img src="docs/assets/Android%202.png" alt="Android settings" width="240" /> | <img src="docs/assets/Android%203.png" alt="Android message thread" width="240" /> |

### Android Tablet

<p align="center">
  <a href="docs/assets/Pad%201.png"><img src="docs/assets/Pad%201.png" alt="Tablet split view" width="260" /></a>
  <a href="docs/assets/Pad%202.png"><img src="docs/assets/Pad%202.png" alt="Tablet message thread" width="260" /></a>
  <a href="docs/assets/Pad%203.png"><img src="docs/assets/Pad%203.png" alt="Tablet settings" width="260" /></a>
</p>

### Windows

<p align="center">
  <a href="docs/assets/windows-chat.png"><img src="docs/assets/windows-chat.png" alt="Windows conversation" width="260" /></a>
  <a href="docs/assets/windows-chat-dark.png"><img src="docs/assets/windows-chat-dark.png" alt="Windows conversation in dark mode" width="260" /></a>
  <a href="docs/assets/windows-appearance.png"><img src="docs/assets/windows-appearance.png" alt="Windows appearance settings" width="260" /></a>
</p>

### Mac Companion App

<p align="center">
  <a href="docs/assets/Companion1.png"><img src="docs/assets/Companion1.png" alt="Mac Companion dashboard" width="260" /></a>
  <a href="docs/assets/Companion2.png"><img src="docs/assets/Companion2.png" alt="Mac Companion pairing" width="260" /></a>
  <a href="docs/assets/Companion3.png"><img src="docs/assets/Companion3.png" alt="Mac Companion settings" width="260" /></a>
</p>

---

## Requirements

Mac Companion requires macOS 13 or newer and Full Disk Access for Messages data. Sending requires Messages to be running and the appropriate Automation permission. Android requires Android 7.0 / API 24 or newer. Linux runs the Flutter client; Windows runs the native client, with Windows 11 as the primary UI validation environment.

Use the same Wi-Fi for initial setup. Public HTTPS access is optional and requires your own proxy or tunnel. Platform engineering folders do not establish equal support on every OS.

## What it does

Read and send texts, attachments and voice messages; browse history, replies, reactions, stickers and media. Clients maintain local caches and catch up after reconnecting. Hidden conversations/messages and read state have separate synchronization rules.

Optional Android FCM push uses your own Firebase project. Keep-alive and IMCore message actions are also optional and off by default; OS permissions and capability checks apply.

## Security

A five-minute, single-use invitation gives each device an independent credential. Revoke lost devices in Companion. LAN HTTPS/WSS pins the paired certificate; public HTTPS uses system trust. Local HTTP port 3000 is for Companion/proxies, and devices normally use TLS port 3001.

FCM previews can contain sender names and message text. A public proxy may terminate TLS. This is not application-level end-to-end encryption. See [connection](docs/features/connection.md) and [notification privacy](docs/features/notifications.md).

## Install and develop

Download the matching Mac and client packages, launch Companion from Applications, grant access, start the server and create an invitation. Scan or paste the JSON on the client. Detailed steps: [Getting Started](docs/getting-started.md).

For code changes, start with [architecture](docs/ARCHITECTURE.md), [build/test/release instructions](docs/DEVELOPMENT.md), then the relevant feature or platform document. Engineering references are maintained in Chinese with code and API identifiers unchanged.

## Acknowledgments

[BlueBubbles](https://github.com/BlueBubblesApp) and [imsg](https://imsg.sh) informed research into Messages behavior. They are independent projects. Third-party graphics and libraries retain their [notices](MicaGoWindowsClient/THIRD-PARTY-NOTICES.md) and [symbol attribution](MicaGoFlutterClient/tool/compat_symbols/NOTICE.md).

made with ♥️ for everyone

# Getting started

**English** · [简体中文](getting-started.zh-Hans.md) · [繁體中文](getting-started.zh-Hant.md)

micaGO connects your devices to Messages on your own Mac. Android and Linux use the Flutter client; Windows has a separate native client.

## Install and authorize the Mac

1. Download the Mac Companion and the client for your device from [Releases](https://github.com/cinmou/micaGO/releases).
2. Move Companion to Applications and launch it. macOS 13 or newer is required.
3. Grant Full Disk Access in System Settings so the backend can read Messages. Restart the backend after changing the permission if needed.
4. Sign in to Messages on the Mac. Sending requires Messages to be running and Automation permission when macOS requests it.

Start the server in Companion and confirm it is reachable. The local control address defaults to `http://127.0.0.1:3000`; devices use HTTPS on port 3001.

## Pair a device

1. Use the same Wi-Fi for the first connection.
2. In Companion's Create Connection card, generate a pairing code.
3. On the client, scan the QR or paste its connection JSON. Windows and Linux can use JSON without a camera.
4. Complete the connection. An expired or used invitation needs a new code on the Mac.

The invitation lasts five minutes and works once. The connected device saves a separate credential and normally reconnects without scanning again. Never paste pairing JSON into a public issue.

Confirm that chats load and realtime connects. Use an existing conversation to check sending; an uncertain send result must not be retried automatically.

## Optional next steps

- [Remote access](remote-access-cloudflare.md) adds your own public HTTPS address.
- [Firebase setup](setup/firebase/README.md) enables optional Android push. Keep-alive is another optional path; neither is needed for initial pairing.
- [Manual checks](manual-test-flow.md) cover cross-device read state, attachments and background notifications.

Revoke a lost device in Companion. Do not reset the entire relay database just to clear cached messages. See [documentation](index.md) for current behavior and development references.

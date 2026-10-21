# micaGO Flutter client

Android / Linux 聊天客户端，连接自己的 Mac 服务端。Windows 使用[独立 WinUI 客户端](../MicaGoWindowsClient)。

```sh
cd MicaGoFlutterClient
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

Linux 在 Linux 环境使用 `flutter build linux --release`。Android 最低 API 24；其他平台工程目录不等于已经验收的产品。

- [安装与配对](../docs/getting-started.zh-Hans.md)。
- [Flutter 代码和平台规则](../docs/platforms/flutter.md)。
- [消息与发送确认](../docs/features/messaging.md)、[未读](../docs/features/unread.md)、[媒体](../docs/features/media.md)。
- [可选通知与推送](../docs/features/notifications.md)。
- [构建与发布](../docs/DEVELOPMENT.md)。

设置备份不包含设备凭据，恢复后仍需配对。HTTP 和原生 WebSocket 使用 header 鉴权；没有通过 URL 令牌连接的当前网页客户端。

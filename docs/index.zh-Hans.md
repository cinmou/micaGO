# micaGO 文档

[English / 工程入口](index.md) · **简体中文** · [繁體中文](index.zh-Hant.md)

安装从[快速上手](getting-started.zh-Hans.md)开始。Android 和 Linux 使用 Flutter 客户端，Windows 使用独立原生客户端；它们都连接自己的 Mac。

- [客户端连接](android-client-connection.md)：扫码、粘贴 JSON、线路和常见连接错误。
- [外网连接](remote-access-cloudflare.md)：可选的 Cloudflare Tunnel。
- [Firebase 推送](setup/firebase/README.md)：自己的项目、配置文件和通知预览。
- [推送故障排查](setup/firebase/troubleshooting.md)。
- [手动检查](manual-test-flow.md)：实际收发、多端已读和后台通知。

开发和文档审查从[完整入口](index.md#development)进入。建议按[架构](ARCHITECTURE.md)、[连接](features/connection.md)、[消息](features/messaging.md)、[未读](features/unread.md)、[媒体](features/media.md)、[通知](features/notifications.md)的顺序阅读。

配对码有效期 5 分钟，只能使用一次。设备兑换独立凭据后正常重连不需要再扫码。丢失设备时在 Mac 撤销配对，不要把二维码或凭据贴进公开日志。

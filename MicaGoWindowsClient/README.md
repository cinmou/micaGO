# micaGO Windows

micaGO 的原生 Windows 客户端，使用 C#、.NET 10、WinUI 3 和 Windows App SDK 2.2。

当前版本已经建立 WinUI 3 双栏聊天界面和真实服务器连接链路，包括配对 JSON、LAN/Public 线路探测、Windows Credential Manager 凭据存储、会话列表、历史消息和文本发送。2026-07-19 已在 Windows 11、Visual Studio 2026、.NET 10.0.302、Debug x64 下完成首次编译和启动验证；仍属于开发中的连接版 MVP，不能视为可发布版本。

## Windows 首次接手

请先阅读：

- [首次构建与验证](docs/WINDOWS_FIRST_BUILD.md)
- [连接协议与凭据安全](docs/CONNECTION_PROTOCOL.md)
- [代码结构](docs/ARCHITECTURE.md)
- [功能完成度和剩余工作](docs/IMPLEMENTATION_STATUS.md)

解决方案入口：`micaGO.Windows.sln`。

## 当前技术选择

- UI：WinUI 3；原生标题栏与侧栏共享低 tint 的 `MicaBackdrop`，联系人栏是聊天内容内的独立圆角表面，聊天画布使用不透明纯色
- 显示：Per-Monitor V2 DPI awareness，初始窗口和最小尺寸按当前显示器缩放率换算
- 运行时：.NET 10
- Windows App SDK：2.2.0 stable
- 分发模式：暂时为 unpackaged、自包含运行；确认连接稳定后再加入 MSIX
- 凭据：token 存入 Windows Credential Manager，不写入配置文件
- 普通配置：`%LOCALAPPDATA%\micaGO\connection-profile.json`
- 设计参考：保留 Flutter Pad 双栏布局，只参考 Unigram 的视觉密度和 Fluent 状态，不复制其 GPL 源码、XAML 或资源

## 当前边界

WebSocket、delta 补漏、SQLite、完整未读状态、媒体预览/查看器、托盘、通知和 MSIX 尚未完成。详细状态见 [IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md)。


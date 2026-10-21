# micaGO Mac Companion

SwiftUI 菜单栏应用，管理 Go 后端、配对、设备、同步规则、可选 Firebase 和隧道。它不是聊天客户端。

在 Xcode 打开 `MicaGoCompanion.xcodeproj`，或从仓库根目录执行：

```sh
xcodebuild -project MicaGoServer/micago-mac-companion/MicaGoCompanion.xcodeproj -scheme MicaGoCompanion -configuration Debug build
```

构建阶段将后端和 IMCore helper 放进 App Resources。后端读取 Messages 需要完全磁盘访问，发送需要 Messages 运行和 Automation 权限。

- [Mac 平台规则](../../docs/platforms/macos.md)：窗口、进程、隧道、权限、更新。
- [开发与发布](../../docs/DEVELOPMENT.md)：DMG、签名、公证和 appcast。
- [配对和网络](../../docs/features/connection.md)。

安装包、源码构建和用户自选后端可能不同，排查前核对真正运行的二进制。不要接管外部服务或恢复第二套窗口/更新引擎。

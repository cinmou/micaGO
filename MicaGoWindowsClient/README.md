# micaGO Windows

独立 WinUI 3 / .NET 10 客户端，使用 Windows App SDK 2.2。连接同一套 micaGO 服务端，提供聊天、附件、原生通知和可选托盘。

<p>
  <img src="../docs/assets/windows-chat.png" alt="Windows conversation" width="640" />
</p>

## 开发入口

在 Windows 上从仓库根目录执行：

```powershell
dotnet run --project MicaGoWindowsClient/tests/micaGO.Core.ContractTests -c Release
dotnet build MicaGoWindowsClient/micaGO.Windows.sln -c Debug -p:Platform=x64
```

[Windows 平台说明](../docs/platforms/windows.md)记录启动、稳定行、联系人、消息布局和发布限制。[开发说明](../docs/DEVELOPMENT.md)记录打包命令。

已保存配对时当前实现直接开主窗口，在后台恢复连接；没有配对或恢复失败才打开连接页。不要参考旧实施记录恢复已删除的启动 XAML。

联系人从本地 `.vcf` 导入。使用[第三方资源](THIRD-PARTY-NOTICES.md)时保留许可证；不要恢复旧 Google/CSV 导入。

## 验证边界

Core 契约测试覆盖协议与消息语义，不能代替 Windows 原生验证。修改后按[手动检查](../docs/manual-test-flow.md)验证 Release 启动、DPI、主题、IME、通知、托盘及可选摄像头。

ZIP 使用 `scripts/package-release-x64.ps1`，安装器使用 `scripts/build-installer-x64.ps1`。不以旧的 RID publish 产物代替正常 x64 构建。

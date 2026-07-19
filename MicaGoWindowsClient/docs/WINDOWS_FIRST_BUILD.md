# Windows 首次构建与验证

## 当前事实

这套代码最初在 macOS 上编写并完成 XML/XAML 静态解析。2026-07-19 已在 Windows 11、Visual Studio Community 2026 18.8、.NET SDK 10.0.302、Debug x64 下完成首次 WinUI 编译和启动：0 warning、0 error，五项 Core 契约测试全部通过。ARM64、Release、浅色/高对比度和跨显示器 DPI 仍待验证。

## 环境准备

推荐使用 Windows 11。最低目标是 Windows 10 1809（build 17763），但 Mica 仅在 Windows 11 原生显示。

安装以下组件：

1. Visual Studio 2026，或最新 Visual Studio 2022 17.14。
2. Visual Studio Installer 中的 `WinUI application development` workload。旧版安装器中可能显示为 `Windows application development`。
3. .NET 10 SDK。
4. Windows 10/11 SDK 和 MSBuild。
5. 在 Windows 设置中启用 Developer Mode。

微软当前推荐 Visual Studio 2026；最新 Visual Studio 2022 仍可尝试，但如果遇到 .NET 10 或 WinAppSDK 2.2 targets 不兼容，先升级 Visual Studio，而不是降低项目目标版本。

## 首次构建

1. 打开 `MicaGoWindowsClient\micaGO.Windows.sln`。
2. 等待 NuGet 恢复 `Microsoft.WindowsAppSDK 2.2.0`。
3. 将启动项目设为 `micaGO.App`。
4. 首次选择 `Debug | x64`，不要先尝试 ARM64。
5. 执行 `Build > Rebuild Solution`。
6. 编译通过后按 `F5` 启动。

也可以在 Developer PowerShell 中执行：

```powershell
dotnet restore .\micaGO.Windows.sln
dotnet build .\micaGO.Windows.sln -c Debug -p:Platform=x64
```

纯 Core 配对契约测试不依赖 WinUI，也不依赖第三方测试框架：

```powershell
dotnet run --project .\tests\micaGO.Core.ContractTests\micaGO.Core.ContractTests.csproj
```

预期输出为五条 `PASS`，进程退出码为 `0`。

## 首次启动预期

1. 窗口约为 `1180 x 760`，Windows 11 显示 MicaAlt 背景。
2. 应用先检查已保存连接；首次启动没有配置时进入配对页。
3. 粘贴 micaGO 配对 JSON 后点击 `Connect`。
4. 应用并行检查所有 LAN 地址，选择完成 health+auth 最快的线路。
5. LAN 全部失败后才检查 Public 地址。
6. 连接成功后进入双栏聊天页并调用 `/api/chats`。
7. 选择会话后调用 `/api/chats/{guid}/messages`。
8. 可发送的会话中按 Enter 调用 `/api/chats/{guid}/send`。

## 连接验收清单

- 服务端 `/api/health` 返回 HTTP 200 和 `{"ok":true}`。
- `POST /api/auth/check` 使用 Bearer token 后返回 HTTP 200。
- 左下角显示实际连接 URL，不显示 `Demo mode`。
- 设置页显示 `LAN` 或 `Public`、当前 URL 和探测耗时。
- 重启应用后无需重新粘贴 JSON。
- Windows Credential Manager 中存在 `micaGO.Windows/server-token`。
- `%LOCALAPPDATA%\micaGO\connection-profile.json` 中不存在 token。
- 设置页执行 Disconnect 后，上述凭据和配置均被删除。

## 常见问题

**找不到 WinUI targets 或 XAML 编译器**

打开 Visual Studio Installer，确认安装 `WinUI application development`，并确认 .NET 10 SDK 可由 `dotnet --list-sdks` 看到。

**NuGet 无法找到 `Microsoft.WindowsAppSDK 2.2.0`**

检查 `nuget.org` package source 是否启用，然后执行 `dotnet nuget locals all --clear` 和重新 restore。不要先把包降级到 1.x。

**局域网一直超时**

确认 Windows 和 Mac 在同一网络、服务端监听的不是 `127.0.0.1`、macOS 防火墙允许服务端端口，并用 Windows 浏览器打开配对 JSON 中的 `/api/health` 地址。

**Public HTTPS 失败但浏览器能打开**

当前客户端不会绕过 TLS 证书错误。检查证书链、主机名和系统时间，不要加入“忽略证书验证”的临时代码。

**Credential Manager 写入失败**

当前版本通过 Win32 `CredWriteW` 保存通用凭据。先确认应用运行在普通桌面用户上下文；记录 Win32 错误码，但不要记录或截图 token。

## 首次构建后的记录

首次 Windows 验证时请记录：Windows build、Visual Studio 版本、.NET SDK 版本、目标架构、首个编译错误全文和运行时异常堆栈。修复应提交到源码和本文档，避免只在本机 Visual Studio 属性中修改。


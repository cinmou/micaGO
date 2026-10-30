# 开发、测试与发布

下面命令从仓库根目录开始。版本以各组件版本文件为准；目前为 0.91.0（Muscovite），Flutter build number 为 91。改版本时保留历史版本比较测试中的旧样本。

## 本地开发

Go 模块要求 Go 1.26.7，SQLite 使用 cgo。后端实际运行需要 macOS、Messages 数据和相应权限。

```sh
cd MicaGoServer/micago-server
go test ./...
go vet ./...
go run ./cmd/micago
```

Companion 使用 Xcode。其构建阶段会带上 Go 后端和 IMCore helper。

```sh
cd MicaGoServer/micago-mac-companion
xcodebuild -project MicaGoCompanion.xcodeproj -scheme MicaGoCompanion -configuration Debug build
```

Flutter 使用本机 Flutter SDK。先执行 `flutter --version`，依赖要求见 [pubspec.yaml](../MicaGoFlutterClient/pubspec.yaml)。

```sh
cd MicaGoFlutterClient
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
# Linux 开发机上使用 flutter build linux --release
```

Windows 使用 Windows、.NET 10 与 Windows App SDK 2.2 对应的桌面构建环境。

Android 图标入口使用 `activity-alias`。本机 Flutter 3.44.3 的源码和 APK Manifest 解析器均只查找 `activity`，`flutter run` 可能报找不到启动入口，`--use-application-binary` 也不能绕过。调试时先 `flutter build apk --debug`，再 `adb install -r build/app/outputs/flutter-apk/app-debug.apk`，用 `adb shell am start -n com.micago.message.mica_go/.MainActivity` 启动，然后 `flutter attach`。不要为绕过工具限制增加第二个桌面图标。此处启动与 attach 步骤仍需连接安卓设备执行验证。

```powershell
dotnet run --project MicaGoWindowsClient/tests/micaGO.Core.ContractTests -c Release
dotnet build MicaGoWindowsClient/micaGO.Windows.sln -c Debug -p:Platform=x64
```

macOS 上的 Core 测试不等于 WinUI 构建通过。XAML、Composition、通知注册和安装包启动需要 Windows 验证，见 [Windows 说明](platforms/windows.md)。

## 按改动选检查

| 改动 | 检查 |
| --- | --- |
| Go 行为或 API | `go test ./...`、`go vet ./...`；并发修改另跑相关 `go test -race` |
| Companion | Xcode 构建和对应的脚本回归；窗口改动还需实际打开检查 |
| Flutter | analyze、相关测试；涉及原生插件时构建对应平台 |
| Windows | Core 契约测试、Windows 构建；原生界面改动做实机检查 |
| 文档 | 本地链接、锚点、代码路径、命令和三语言入口；纯文档修改不重打应用 |

Companion 的针对性检查在 [scripts](../MicaGoServer/micago-mac-companion/scripts)：`test-api-client.sh`、`test-connection-payload.sh`、`test-dashboard-window.sh`、`test-dashboard-lifecycle.sh`、`test-backend-restart.sh`、`test-startup-ownership.sh`、`test-tunnel-recovery.sh`、`test-update-validation.sh` 等。脚本通过只证明它覆盖的行为。`test-dashboard-lifecycle.sh` 需要 macOS 15+ 的桌面会话，使用隔离的 SwiftUI 测试应用验证无窗口启动、隐藏窗口恢复、最小化和关闭后重开，不启动后端或读取联系人。

旧 smoke 脚本有些早于独立设备凭据和 TLS。运行前先读脚本，不把旧脚本的协议假设当成当前要求。跨设备验收使用[手动检查](manual-test-flow.md)。

## Mac 发布

使用现有 [package-dmg.sh](../MicaGoServer/micago-mac-companion/scripts/package-dmg.sh) 与 `create-dmg`。本地未签名包用于开发；公开包需 Developer ID 签名、公证、staple 和 Sparkle 签名。

```sh
brew install create-dmg
cd MicaGoServer/micago-mac-companion
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
APPLE_TEAM_ID="TEAMID" \
NOTARIZE=1 NOTARY_KEYCHAIN_PROFILE="micaGO-notary" \
VERSION=0.91.0 scripts/package-dmg.sh
```

公证凭据预先由 `notarytool store-credentials` 放入钥匙串；不要把密码和私钥写进文档或 shell 历史。Sparkle EdDSA 私钥也由发布环境安全提供。

默认输出在 `MicaGoServer/micago-mac-companion/build/release/`：DMG 和匹配的 `appcast.xml`。公证包默认生成 appcast；它的 URL、版本、字节大小和 Ed25519 签名会由 `validate-update.swift` 对照内嵌公钥检查。

DMG 包含 universal App 和后端，最低 macOS 13。链接器与 SDK 不匹配时，核对 `GO_DEVELOPER_DIR`，不要降低目标系统兼容性掩盖构建问题。

挂载 DMG 后实际查看图标、Applications 快捷方式和箭头位置。Finder 坐标使用 point，背景图的 point 尺寸为像素数乘 72 / DPI。打包时重新生成背景，不复用旧坐标猜测。

Sparkle 是唯一更新引擎。发布前用签名旧版到新版做更新检查，核对配对身份、设置、后端版本和历史。Debug 构建不能证明签名更新可用。

## Android、Linux 与 Windows 发布

Android release 构建使用有效的 release keystore；密钥由发布环境提供。输出为 `MicaGoFlutterClient/build/app/outputs/flutter-apk/app-release.apk`。Linux 在 Linux 环境构建并打包产物，不用 macOS 的构建结果代替。

Windows ZIP 使用已有脚本，安装器包装同一份 ZIP 内容：

```powershell
./MicaGoWindowsClient/scripts/package-release-x64.ps1
./MicaGoWindowsClient/scripts/build-installer-x64.ps1
```

ZIP 在 `MicaGoWindowsClient/artifacts/micaGO-release-x64.zip`；安装器需要 Inno Setup 6，输出同目录的 `micaGO-Setup-x64.exe`。保留正常 x64 Release build 路径，不能换成尚未通过启动验收的 RID publish 产物。

脚本负责通知 Runtime DLL、Twemoji SVG、架构与语言资源裁剪。打包后仍须验证启动、配对和通知。

## GitHub Release

[release.yml](../.github/workflows/release.yml) 在版本标签触发时构建产物并创建 draft；手动运行可只生成 artifacts。逐个查看 job 和实际附件，不以 workflow 名字推断发布完成。

Mac 包在本地签名公证，上传同一轮生成的 DMG 和 `appcast.xml` 后再发布 draft。当前 feed 指向 latest release 的 appcast，缺少该附件会导致已安装的 Companion 检查更新失败。不要用另一份 DMG 搭配旧 appcast。

Release note 用英文，按上版的平台结构描述实际变化，重点写用户可见功能、修复和限制。不要照搬历史 beta 文案或把自动检查写成实机验收。

## 维护文档

功能规则更新到 `features/`，平台限制更新到 `platforms/`，构建发布更新到本页。重要取舍写短 ADR。临时排查和任务进度留在当前任务中，确需跨会话的计划才放到 `plans/`。

旧规格和实施过程由 Git 历史保存；不再把每次会话追加到 AGENTS、CLAUDE 或新总结文件。

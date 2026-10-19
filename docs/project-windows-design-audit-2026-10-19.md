# 项目成熟度与 Windows 界面审计

日期：2026-10-19。对象：当前 0.88.0 工作区，包含尚未提交的通知改动。范围是源码、构建流程、文档和微软设计规范；本轮未在 Windows 运行、未复现原生崩溃，也没有修改应用代码。以下区分可确认的问题、待运行验证的风险和设计建议。

## 可确认的问题

### P1：Windows 启动重新阻塞在旧连接恢复上

`MicaGoWindowsClient/src/micaGO.App/Views/ConnectionPage.cs:80` 的 Loaded 调用 RestoreConnectionAsync；116 行开始的流程 SetBusy(true)，以 8 秒 CancellationToken 探测旧连接，成功后自动打开主窗口。195 行的 SetBusy 会禁用 JSON 输入、扫码、图片导入及连接按钮。

旧地址不可达时，用户无法立即输入新配对信息。这与现有工作指南关于启动输入保持可用、此前自动恢复路径触发过原生启动问题的约束冲突。可以确认阻塞入口重新出现，不能据此断言旧崩溃必然复现。

建议先恢复交互可用的启动行为。若以后保留静默恢复，应单独验证 Release 实际安装包：启动、旧地址离线、撤销凭据、配对期间窗口切换，以及用户开始新配对时旧请求取消。

### P1：质量检查没有成为每次变更的门槛

`.github/workflows/release.yml:33` 只接受手动运行或版本标签；当前没有 PR/push 检查工作流。发布流程会跑 Flutter analyze/test 和 Windows Core 契约测试，但没有 Go test/vet，也没有 Companion 的恢复/归属测试。问题可能到打标签准备发布才被发现。

建议新增独立 PR CI，按路径运行 Go、Flutter、Windows Core 和可独立编译的 Swift 测试；Windows 安装/启动冒烟另外在 Windows runner 执行。发布流程复用这些检查，保留已经验证的普通 x64 build 打包路径。测试数量不能代替平台启动、锁屏、权限和 UI 验收。

### P1：Android 相机进程恢复仍有缺口

`MicaGoFlutterClient/lib/features/chats/attachment_panel.dart:182` 直接等待 image_picker.pickImage 返回；当前 lib 下没有 retrieveLostData 调用。Android 在外部相机期间回收进程时，原来的 Future 无法恢复，可能丢失刚拍的附件。聊天输入控制器及暂存附件也需要独立确认草稿恢复策略。

建议采用 image_picker 已有的 lost-data API，先记录操作目的、会话路由和配对身份，重启后只恢复到用户确认界面，不自动发送。头像和背景选择也使用 picker，不能把所有找回的图片都当成聊天附件。

### P2：Windows 消息操作缺少完整键盘入口

`Views/ShellPage.xaml:330` 的 MessageList 为 IsTabStop=False、SelectionMode=None；`Styles/MicaGoTheme.xaml:235` 的消息条目同样不是 Tab 停靠点，消息菜单主要由 RightTapped 打开。当前 Shell 没有对应的消息焦点/上下文菜单键盘流程；分栏拖动也只有指针实现。

建议补齐进入消息区的焦点入口、方向键定位、Shift+F10/菜单键和焦点恢复。不要让每一行都成为一个独立 Tab 停靠点。用 Narrator、Accessibility Insights 和高对比度验证实际自动化树，不能把 XAML 有文本视为已经可访问。

### P2：窄窗口缺少单栏布局

`MainWindow.cs:16` 最小宽度为 880 DIP；Shell 固定保留聊天栏，SizeChanged 主要调整分栏比例，没有窄宽度单栏状态。在工作区较窄、高 DPI 或左右贴靠时，聊天内容和设置尾部控件空间不足；最小宽度限制也影响贴靠组合。

建议按可用窗口 DIP 决定列表/聊天单栏切换，保留宽窗口双栏与用户拖动比例。具体断点按实际最小可用内容宽度确定，微软示例断点不是所有应用必须照抄的数值。

### P2：文档和实际状态发生漂移

根 README.md:165 仍把默认 3000 端口写成 LAN 可访问；当前 Go app.go:493 明确将 HTTP 绑定到 127.0.0.1，设备应走 TLS 端口。Windows IMPLEMENTATION_STATUS 仍列出 Google 联系人、手动“加载更早”及只有 8 个测试等历史状态，与当前 vCard、滚动分页和契约测试文件不符；工作指南与实际设置入口、启动行为也有冲突。

建议收敛成一份可查的当前支持矩阵，将旧实现记录与当前使用说明分开；检查用户能否只按 README 完成首次安装和连接。

### P2：开源维护与 Windows 分发保障还不完整

已有 MIT 许可和第三方资源声明，但当前没有 SECURITY.md、CONTRIBUTING.md、问题模板或自动依赖安全检查。Windows 打包脚本生成 SHA-256，未见 Authenticode 签名与验签步骤；README 也把签名留作发布要求。这是发布链路的缺口，不代表已检查过所有已发布安装包的签名状态。

建议明确私密漏洞报告渠道和支持版本，提供可复现问题模板；Windows 发布前加入签名/验签及安装卸载检查。MSIX/Store 可以另行评估，采用它们并不是符合 Windows 界面的前提。

## Windows 界面调整建议

双栏聊天、头像和气泡本身适合 Windows。Telegram/Unigram 感主要来自以下组合：ShellPage.xaml:256 的覆盖式 Acrylic 联系人栏、384 行开始的浮动胶囊编辑器（圆角 28），以及 ShellPage.xaml.cs:307 中设置页接管聊天侧栏的方式。源码注释也明确写了 Unigram。这些属于设计取舍，不能直接判为违反微软规范。

建议以 WinUI Gallery 的导航、设置和可访问性交互为参照，做一轮有边界的调整：

- 保留稳定的双栏聊天及现有增量列表。设置改用明确的页面导航层级，优先复用 NavigationView；是否采用独立设置窗口先评估现有主窗口生命周期，不增设无用的顶层栏目。
- 标题栏、页标题、联系人操作区各有职责。统一标题栏行高与系统 caption 按钮高度；目前自定义行为 48 DIP，而 PreferredHeightOption 为 Standard，需要 Windows 实机核对对齐。
- 联系人栏收回正常布局行，减少消息从其背后穿过的视觉效果；编辑器使用常驻底部输入区、克制的圆角和原生按钮/CommandBar 交互。保留 TextBox 的 IME、粘贴、Enter/Shift+Enter；不要顺带改动已验证的滚动锚点。
- 固定内容区域使用分层主题表面，Mica 留在窗口基础层，Acrylic 用于确实需要表达覆盖层的地方。现有颜色已有 Light/Default/HighContrast 字典，但仍有自定义硬编码笔刷，可逐步改用系统语义资源。不能声称当前没有高对比度支持。
- 设置页优先语义字号、统一间距和能够重排的尾部控件。可参考官方 Gallery 的 SettingsCard，确认有实际收益再决定是否引入 Community Toolkit；不要为了一个边框加入依赖。
- 连接/状态采用稳定位置的 InfoBar，操作使用原生 Flyout/ContentDialog；消息菜单、隐藏撤销、通知等继续沿用已有合适的原生控件。

建议先修启动交互和键盘入口，再调整窗口布局、导航、编辑器与材质。保留当前 route-qualified 消息身份、ChatListCollection、MessageRow 稳定容器和 ListViewItemPresenter 根模板；不恢复曾造成 Release 崩溃或列表闪烁的旧模板与通用过渡动画。

## 参考与验证边界

[微软现代 WinUI 应用结构](https://learn.microsoft.com/en-us/windows/apps/develop/ui/windows-app-sdk-app-structure)、[Mica 材质](https://learn.microsoft.com/en-us/windows/apps/design/style/mica)、[响应式布局](https://learn.microsoft.com/en-us/windows/apps/design/layout/screen-sizes-and-breakpoints-for-responsive-design)、[键盘交互](https://learn.microsoft.com/en-us/windows/apps/design/input/keyboard-interactions)、[WinUI Gallery 设置页源码](https://github.com/microsoft/WinUI-Gallery/blob/main/WinUIGallery/Pages/SettingsPage.xaml)。同时检索了 WinUI 社区关于导航与材质的反馈，具体规范判断以上述平台资料和当前源码为准。

本轮未重新运行测试或构建；前一轮 495 项 Flutter 测试与 Android APK 结果不能证明 Windows 布局、安装或无障碍已通过。下一次界面修改至少应在 Windows 验证浅/深/高对比度、100/150/200% 缩放、窄宽、Narrator、Tab/F6/Shift+F10 和 Release 安装后的首次启动。

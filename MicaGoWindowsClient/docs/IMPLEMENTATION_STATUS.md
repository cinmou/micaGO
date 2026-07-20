# 功能完成度

更新时间：2026-07-20。当前 Windows 产品版本：`0.66.0`。

“代码完成”表示源码路径已经实现；“Windows 待验证”表示尚未通过 Windows 编译或运行，不能视为验收通过。

| 模块 | 状态 | 当前内容 | 下一步 |
| --- | --- | --- | --- |
| WinUI 3 工程 | Debug x64 已验证 | .NET 10、WinAppSDK 2.2、x64/ARM64、unpackaged；VS 2026 + .NET 10.0.302 编译 0 warning/error | 验证 ARM64 和 Release |
| Mica、标题栏与 DPI | Windows 11 暗色已验证 | 原生 caption buttons、低 tint Mica 标题栏/侧栏、独立联系人栏、纯色聊天画布、局部圆角、Per-Monitor V2 | 验证浅色、高对比度和跨显示器切换 |
| 配对 JSON | 代码完成，Windows 待验证 | v1/v2/v3、隐藏地址过滤、URL 校验 | 使用真实 Companion JSON 验收 |
| LAN/Public 选择 | 代码完成，Windows 待验证 | 多 LAN 并行 health+auth、最快线路、Public 回退 | 增加逐线路诊断和手动固定线路 |
| 凭据安全 | 代码完成，Windows 待验证 | Windows Credential Manager，配置不含 token | Windows 上检查写入、恢复和删除 |
| 会话列表 | 已接入 | 真实 `/api/chats`、搜索、SQLite 缓存、Google 名称/头像、多路由联系人合并、本地置顶排序 | 自定义别名与群聊组合头像 |
| 历史消息 | 已接入 | cache-first、50 条分页、切换取消旧请求、服务端页合并后从 SQLite 重建视图 | 将“加载更早”按钮改为纯滚动触发并补加载骨架 |
| 文本发送 | 已接入 | 乐观气泡、失败状态、tempGuid/文本时间窗对账、稳定 presentation key | 文字失败气泡点击重试 |
| WebSocket | 已接入 | Authorization header、重连退避、事件作为 delta catch-up 提示 | 完善前后台生命周期与网络变化监听 |
| delta 补漏 | 已接入 | cursor 持久化、循环拉取、SQLite GUID upsert | 增加 API fake 与乱序压力测试 |
| SQLite | 已接入 | WAL；chats/messages/settings/contacts/hidden_messages | schema 版本迁移与未读 watermark |
| 未读/置顶/静音/隐藏 | 部分 | 本地 read watermark、实时未读递增、当前会话通知抑制、置顶/静音设置 | 已读回执写回、隐藏管理和同步规则接口 |
| 媒体 | 已接入 | 原生图片缩放/前后切换、WinUI 音视频播放、HEVC playable 回退、另存/系统打开、缓存与详情缩略图 | Share Contract、视频加载骨架和完整媒体页筛选 |
| 附件发送 | 已接入 | 文件多选、批量乐观气泡、顺序上传、进度、取消、失败重试、SQLite 重启自动恢复、安全对账 | 后台传输 API（当前随应用生命周期） |
| 通知与托盘 | 已接入 | AppNotification、点通知打开对应会话、关闭到托盘、托盘最近联系人菜单、设置持久化 | 启动/退出菜单 |
| MSIX | 未开始 | 当前 unpackaged self-contained | 连接稳定后加入 x64/ARM64 MSIX |
| 自动化测试 | 部分 | 8 个 Core 契约测试通过（含 U+FFFC、歧义附件对账、稳定展示标识） | Windows CI、API fake、ViewModel 与 UI 测试 |

## 当前可验收的最短闭环

首次 Windows 编译通过后，只验收以下路径：

```text
启动 -> 粘贴配对 JSON -> LAN/Public 探测 -> 保存凭据
     -> 拉取真实会话 -> 打开会话 -> 拉取 50 条消息 -> 发送文本
     -> 重启自动恢复 -> 设置页 Disconnect
```

这条路径稳定之前，不应同时开始托盘、通知或 MSIX。WebSocket 和 SQLite可以开始设计，但接入 UI 前必须先确定去重与 cursor 持久化规则。

## 已知技术风险

- Debug x64 已完成首次 Windows 编译和 unpackaged 启动；ARM64、Release、浅色/高对比度和跨显示器 DPI 仍未验证。
- `ShellViewModel` 已承接状态与实时同步；页面仍保留 WinUI 事件编排，快速切换会话尚需取消旧请求。
- 乐观消息已有稳定 presentation key；ViewModel 仍需 API fake 压测乱序确认和多批次失败重试。
- Credential Manager 使用 Win32 通用凭据，不是 MSIX 身份下的 `PasswordVault`；转 MSIX 时需要决定是否迁移到 Credential Locker，并提供一次性迁移。
- 媒体缓存已落盘且可从设置清理；后续需加入内存 LRU 与解码尺寸限制，避免媒体密集会话占用过高。

## UI 重构（W-UI1，Windows 待验证）

- `MessageBubble` 全量重写为确定性绑定（每次 DataContext 变更全量重置，弃用 VisualState，杜绝容器复用串样式）。渲染分层对齐 Flutter 端：群聊发送者名在气泡上方、送达 footer 与 “Sent with …” 效果标签在气泡下方、回复预览块在气泡上方；媒体永远是独立于文字气泡的无框块（图+文=两个视觉兄弟，对应 Flutter C50）；大 emoji（≤3，84/64/52px）与纯贴纸消息去掉气泡；反应 chip 叠在气泡上角（发出→左上，接收→右上）；每个附件单独渲染（此前只渲染第一个）：图片/视频用 Rectangle+ImageBrush 得到真圆角裁剪并按位图纵横比在 320×306 内定尺寸、视频带播放角标、语音/音频/文件/位置/链接是圆形图标卡片；上传中在气泡上叠进度环+压暗，失败叠红色“未送达”徽标（附件消息）；气泡 ToolTip 显示完整时间。外发气泡使用系统强调色（`AccentFillColorDefaultBrush`+`TextOnAccentFillColorPrimaryBrush`），跟随 Windows 个性化设置。
- Shell：会话行改为 `PersonPicture`（自动首字母+联系人头像）+ 静音/置顶图标 + 强调色未读 pill（99+ 截断）；会话头部去掉无功能的返回键，改 `PersonPicture` 头像；设置入口从标题栏移到侧栏搜索框旁（标题栏只留标题与拖拽区）；发送键改为强调色圆形按钮。`Ui.cs` 提供 x:Bind 函数（头像 ImageSource、可见性、计数文案）。
- 设置页与会话详情页重排为 Windows 11 设置卡片风格：`TitleTextBlockStyle` 页标题 + `MicaGoSettingsCardStyle`（CardBackground/CardStroke、圆角 4、图标|标题+描述|尾部控件）逐项成卡；详情页含 hero 头像块、静音/置顶卡、参与者卡、圆角媒体网格（Rectangle+ImageBrush，绑定 `PreviewBrush`）。
- 主题：删除未用的自定义笔刷（含硬编码 accent）；新增设置卡样式与 header 样式。以上全部**未经 Windows 编译验证**，需在 Windows 上跑一次 Debug x64。

## 连接持久化 + 独立配对窗口（W-UI2，Windows 待验证）

- **每次启动都要重新配对的根因**：`ConnectionPage_Loaded` 只显示"粘贴 JSON"提示，`RestoreConnectionAsync()` 是从未被调用的死代码——`ConnectionManager.TryRestoreAsync`（连接文件 + Credential Manager token + 线路探测）一直存在但没接线。现在页面加载即静默恢复（8s 超时），成功直接进主窗口。
- **配对改为独立窗口** `ConnectionWindow`（640×560 DPI 缩放、不可调整大小/最大化、Mica Base、自定义标题栏）。`App` 负责窗口编排：启动先开配对窗口（兼作启动画面，自动恢复成功后换主窗口）；设置页 Disconnect → 关主窗口开配对窗口；`_switchingWindows` 标志保证只有用户关掉最后一个窗口时才 `AppServices.Dispose()`。`MainWindow` 现在只承载 `ShellPage`，`Closed` 时调 `ShellPage.ShutdownAsync()`（停 timer + DisposeAsync ViewModel，终止 WS 重连循环）。
- **配对卡片去嵌套**：页面背景透明，只剩一张 `Background=Transparent` 的卡片直接透出窗口 Mica（CardStroke 描边），Connect 强调色按钮移到卡片右上角；文案全量本地化（`conn*` 键 ×3 语言）。

## 气泡显示逻辑补全（W-UI3，Windows 待验证）

对照 Flutter 端补上此前缺失的显示项（均在 `MessageBubble` + `ShellPage`）：

- **回复跳转**：点回复预览块 → 静态事件 `ReplyJumpRequested`（`ThreadPresentation.NormalizeTarget` 公开化）→ ShellPage `ScrollIntoView` + 容器透明度闪烁两次。
- **位置卡可点**：下载 vlocation 原文件，正则取第一个 URL，`Launcher.LaunchUriAsync` 打开地图。
- **URL 预览卡**：正文恰含一个 URL 且无服务器 link 附件时，气泡上方出现链接卡（图标+标题+域名，点开浏览器）；标题异步抓 `<title>`（5s 超时、静态缓存 200 条、失败静默降级为域名）。
- **交互式 App 消息卡**：`BalloonBundleId` 非空且无文字无媒体的消息不再落入"Unsupported"系统行（`ThreadPresentation.IsSystem` 排除），渲染 App 卡片（手写/Digital Touch/bundle 尾段名）。
- **发送效果播放**：点 "Sent with …" 标签 —— 气泡效果（Slam 回弹缩放+倾斜、Loud 关键帧抖动、Gentle 从小到大）用 Storyboard 作用于 `BubbleTransform`；屏幕效果经 `ScreenEffectRequested` → ShellPage `EffectCanvas` 播 32 个 emoji 粒子（🎉❤️🎈🎆⚡✨ 按效果映射，升/降向 + 透明度关键帧，完成后清空画布）。**Invisible Ink**：`InkCover` 遮罩默认盖住消息，点遮罩显形、点标签重新遮住（`RevealedInkKeys`）。
- **动画**：新消息入场（<15s 新 key，240ms 淡入+12px 上升）；网络加载的媒体 180ms 淡入（内存缓存命中直渲，C51 规则）；footer 文案变化 160ms 淡入（C72 近似，无行高滑动）。防历史动画：`ResetTransientState()`（ShellPage 每次开会话调用）+ 700ms 开场宽限期。
- 仍未迁移（交互功能非显示）：多选/批量转发/隐藏（C64）、消息 tombstone、合并视图 beta、Echo/Spotlight 全屏原版粒子系统。

## 消息流增量刷新 + 启动直达 + 设置/详情 Mica（W-UI4，Windows 待验证）

- **发送后跳回顶部的根因**：`ShellViewModel.ReplaceMessages` 每次 `Messages.Clear()`+全量重加，ListView 丢滚动位置。已改为 `SyncMessages` 按 presentation key 做增量 diff（原位替换 / Insert / Move / 截尾），滚动位置保持；未变化的行靠 record 相等性跳过（附件列表引用未变即相等）。
- **启动不再闪配对窗口**：`ConnectionManager.HasSavedProfileAsync`（本地文件+凭据，无网络）；`App.LaunchAsync` 有保存配对 → 直接开主窗口，`ShellPage_Loaded` 在 Api 为空时后台 `TryRestoreAsync`（15s），失败才切配对窗口。托盘恢复与通知注册也移到 LaunchAsync。
- **通知点击直达会话**：`NotificationService.ChatActivated`（`NotificationInvoked` 里解析 `chat` 参数）→ App 调度到 UI 线程 → 显示当前窗口 + `OpenChatAsync`。
- **设置/详情 Mica**：两页根背景改 Transparent，透出 ShellPage 的 NavigationView 式 ContentSurface（Layer over Mica）；两页 section 加 `EntranceThemeTransition`（stagger）+`RepositionThemeTransition`；详情页头部改 Unigram 风（返回|64px 头像|名称+状态 左对齐，弃中置 hero）。
- **设置新增"关于"**：侧栏第 4 项（E946）；`AboutSection`＝应用卡（logo/副标题/程序集版本 0.66.0）+ GitHub 链接卡（github.com/cinmou/MicaGo）+ 开源致谢卡（Twemoji CC-BY 4.0 + 非隶属声明），l10n 键 `about/aboutSubtitle/version/viewOnGitHub/openSource`。
- **vCard 导入状态持久化**：导入成功写 `contacts.vcfSummary`（`n|n|n`），清除时清空；Contacts 页加载时 `RestoreVcfSummaryAsync` 还原文案——修复"重启后设置页导入信息消失"。
- **Twemoji 渲染兜底**：`SvgImageSource` 异步失败（缺资产）时经 `OpenFailed` 把 InlineUIContainer 换回系统字形文本，不再留白。

# Windows 客户端

Windows 是独立 WinUI 3 / .NET 应用，不是 Flutter 桌面构建。Core 处理消息与状态语义，Infrastructure 负责网络、存储与系统服务，App 负责原生界面。

## 启动与配对

当前 [App.xaml.cs](../../MicaGoWindowsClient/src/micaGO.App/App.xaml.cs) 会先检查本地已保存配对，有配对则直接显示主窗口并在后台恢复连接；没有配对或恢复失败才显示连接窗口。旧文档中“永不自动恢复”和更早的“配对页 Loaded 阻塞恢复”都不能直接套回当前实现。

ConnectionWindow、MainWindow 和连接页使用代码构建的原生 WinUI 宿主。早期 compiled Window / 启动页 XBF 在 Release 下发生过原生崩溃，不恢复这些 XAML 宿主，除非有隔离的发布与启动验证。

配对支持 v4 JSON、可选摄像头和 QR 图片；识别结果先填入，按连接后才兑换。兑换前检查 Credential Manager。普通连接配置 JSON 不含凭据，Credential Manager 保存设备凭据。

鉴权拒绝会结束当前凭据会话，停止迟到响应和重连，关闭聊天/媒体并清理旧配对内容。普通 403 不按撤销处理。偏好队列保持服务器范围，不能串到新配对。

## 消息与缓存

- 消息与缓存身份保留 `chat_guid + guid`，不单用 GUID。
- `Message.PresentationKey` 保留本地发送到服务端确认的展示身份；`Message.ServerKey` 才是同步隐藏身份。
- `MessageSemantics` 负责正文规范化和发送匹配；`ThreadPresentation` 负责时间、发送者分组、回应、回复、系统消息和脚注。
- `ChatSummary` 和 `MessageRow` 是稳定行对象。更新状态不应替换整行或 Reset 整个列表。
- `ChatListCollection.Apply` 负责聊天列表差异。实时事件只更新受影响路线，旧事件不倒退预览或未读。
- 发送结果不确定时保留待确认状态。文字和附件任务保存到 `pending_sends`，旧 `pending_uploads` 有迁移，不能自动重新发送。
- 历史使用服务端统一多路线游标，每次 50 行。顶部滚动加载旧消息，保留首个可见行的位置；发送与确认保持底部锚点。

不要把本地实时修改再作为旧缓存快照合并，导致临时行复活；切换会话后不能保留其他路线的临时或确认消息。

## 联系人

唯一导入入口是本地 vCard，解析使用 `FolkerKinzel.VCards`。名字不作为合并 key。RFC UID 或持久 fallback ID 提供 `contact_id`；同批导入和后续重复导入都要复用身份。

显式账号关联保存在 `contact_links`，重导入不能拆掉用户的关联。头像按内容哈希本地缓存。清联系人仅清理联系人、关联和头像，不删除聊天或配对。不要恢复 Google OAuth/People 或 CSV 导入界面。

## 原生界面

当前聊天画布延伸到浮动编辑器后方。输入胶囊和独立发送按钮用应用内 Acrylic 模糊聊天背景；Mica 保留在窗口层。系统桌面背景采样不能冒充聊天背景模糊，高对比度使用不透明回退。

底部留白来自实际编辑器高度，包含多行、大字体、录音和多选状态，不用固定高度遮挡最后一条消息。原生 TextBox 的焦点、选择、输入法、粘贴行为应保留。

侧栏仍保留 `ListViewItemPresenter` 模板根，当前选中效果使用覆盖在可视区域上的共用选中指示条；它与实时单行重排动画分开。通用 ItemsControl 进场/容器动画保持关闭，避免回收闪烁。新消息的单次进场由稳定 MessageRow 标记，历史、确认、脚注更新和回收不能重复播放。

Composition 回收要重置 opacity、scale、translation。停止 Translation 动画前先启用 translation，否则切换长会话可能抛出 `E_INVALIDARG`。列表滚动由原生布局与锚点控制，不叠加每条发送的手动滚动动画。

中文文本通过统一 Language 和字体回退处理，图标和 emoji 字体分开。系统字体覆盖不足的 emoji 使用现有 SVG；Twemoji 国旗开关默认关闭，保留[第三方声明](../../MicaGoWindowsClient/THIRD-PARTY-NOTICES.md)。

Ctrl+F 搜索，F6 / Shift+F6 切区域，Shift+F10 / 菜单键打开消息菜单。侧栏宽度可拖动并保存，详情区保留最小宽度；不要让自适应布局覆盖用户拖动结果。

## 通知、托盘与设备

原生通知需要架构匹配的 `Microsoft.WindowsAppRuntime.Insights.Resource.dll`，由项目构建步骤提取。`IsSupported()` 为 true 不保证 `Register()` 成功，保留 HRESULT 供诊断。联系人图失败时应回退为正常通知，不能丢掉投递。

通知偏好在实时连接前载入，初次历史补齐保持静默。通知回复不携带凭据，执行前检查当前会话；不确定发送不能自动重试。

托盘默认关闭，只有用户启用才注册；启用时关窗才隐藏到托盘。托盘资源损坏应关闭该功能，不让应用启动崩溃。菜单保持系统绘制并跟随主题。

设备使用保存在 SQLite 外的稳定随机 ID，注册为 Windows/native，无 FCM。清缓存不能创建另一台重复设备。

## 打包与验证

使用 [package-release-x64.ps1](../../MicaGoWindowsClient/scripts/package-release-x64.ps1) 的正常 x64 Release build 输出，再由安装器脚本包装。不要换成旧的 RID-specific self-contained publish 路径；它曾在激活 Page XBF 时崩溃。

[Core 契约测试](../../MicaGoWindowsClient/tests/micaGO.Core.ContractTests) 覆盖语义与协议；原生构建、Release 启动、DPI、主题、IME、辅助功能、通知和摄像头要在 Windows 上检查。不要把文档中的历史测试数量当作当前覆盖数量。

# Flutter 应用设计审查

审查日期：2026-10-09。范围是 Flutter 客户端的连接恢复、消息页面、附件选择、提示、尺寸适配和无障碍入口。以下结论来自源码与本地回归测试，不代表已经通过 Android 真机、TalkBack 或 Linux 桌面的完整验收。没有新增依赖，也没有替换现有传输协议。

## 本轮已处理

| 问题 | 处理 |
| --- | --- |
| 权限窗口、系统界面失焦后也强制重连 | 区分短暂失焦与 paused/detached；移动端 hidden 单独出现不会被当作真正离开应用。桌面最小化仍算后台。 |
| 相机返回时替换仍然正常的连接 | 真正后台返回时先通过现有认证接口检查保留的连接。正常连接继续使用，连接建立中也不会被重复恢复任务打断；失败才重新选择地址。 |
| 自动加载历史失败冒出临时红色提示 | 删除消息页的自动错误浮层监听。保留已有消息，继续使用连接恢复后的重试路径；用户主动操作的反馈采用统一中性提示。 |
| 普通断线自动弹窗，打断当前操作 | 持续确认的网络问题只在标题栏下显示中性重试卡片。令牌被拒绝保持终止会话、清理记录及重新配对弹窗。 |
| 相机、文件选择回调访问已销毁页面 | 附件面板在异步返回、读取文件和错误回调前检查 mounted；权限请求也进入同一个异常处理范围。 |
| Linux 暴露移动端相机和相册权限入口 | 桌面改用照片选择及文件选择，隐藏不支持的系统相机和移动端相册权限提示。 |
| 矮屏下表情面板高度计算抛异常 | 当屏幕高度不足时同时收缩最小与最大高度，避免 clamp 的下界超过上界。初始高度和拖动使用相同范围。 |
| 提示操作目标过小，状态不被辅助技术播报 | 提示按钮最小尺寸改为 48×48，统一提示卡片加入 liveRegion。 |

连接恢复行为参考 [BlueBubbles 生命周期实现](https://github.com/BlueBubblesApp/bluebubbles-app/blob/35112ce7a2d46cdc98f96662b491c0b4dd591753/lib/services/backend/lifecycle/lifecycle_service.dart) 和 [SocketService](https://github.com/BlueBubblesApp/bluebubbles-app/blob/35112ce7a2d46cdc98f96662b491c0b4dd591753/lib/services/network/socket_service.dart)。沿用其状态区分和连接存活检查的思路，没有复制 Socket.IO、后台 isolate 或平台专用服务。Flutter 对 inactive 的定义也明确包含系统窗口、通知栏及失焦，不能把每次 resumed 都当成网络已断：[AppLifecycleState](https://api.flutter.dev/flutter/dart-ui/AppLifecycleState.html)。

## 仍建议处理

### P1：拍照期间 Android 回收进程后，所选照片没有恢复入口

`lib/features/chats/attachment_panel.dart` 使用 image_picker，但客户端没有调用 `retrieveLostData()`。聊天输入和待发送附件目前也主要保存在 `MessageThreadScreen` 的内存状态中。低内存下从系统相机回来可能重新启动应用，原来的 Future 无法收到结果，照片或草稿就会丢失。这与单纯的网络断线不同。

建议使用插件现成的 `retrieveLostData()`，并在打开选择器前保存用途及聊天 route：聊天附件、联系人头像和聊天背景必须区分。恢复后先让用户确认，不自动发送，也不把照片放进另一联系人的会话。配合保存文本草稿和待选附件清单；退出登录或令牌被拒绝时一起清理。此次未实现这套草稿恢复流程。[image_picker 的 Activity destruction 指南](https://pub.dev/packages/image_picker#handling-mainactivity-destruction)

### P2：部分手势入口的触摸目标和无障碍标签不足

`lib/features/chats/chat_list_screen.dart` 的拖动未读徽标只有 9 DIP 外边距，小圆点的整体抓取区域约 30×30；`message_thread_screen.dart` 的失败重试 footer 直接以小字号 Row 接收点击。表情分类是未提供 tooltip 的图标按钮，分类栏高度 44、上下内边距各 6，实际按钮区域也偏小。

建议保持图标和文字的视觉大小，在外层提供至少 48×48 的交互区域。给重试、标为已读及表情分类增加本地化语义标签和键盘入口。Flutter 有现成的 `Semantics`、`Tooltip`、`FocusableActionDetector` 和 accessibility guideline tests，可以直接复用。需要用 TalkBack 验证实际朗读及焦点顺序，不能仅凭静态检查判定通过。[Flutter 无障碍检查项](https://docs.flutter.dev/ui/accessibility)

### P2：应用内消息通知仍然遮住标题栏，并有独立提示样式

`lib/features/home/home_screen.dart` 的 `_InAppMessageNotification` 使用独立 OverlayEntry，位置为状态栏下 6 DIP，卡片圆角 22、阴影和动画也与统一状态提示不同。启用应用内通知后，它会遮挡标题栏，并可能与普通提示同时出现。

建议保留消息通知的头像和点击进入聊天的能力，将它纳入同一个顶部提示队列，并统一到标题栏下的位置。优先级为身份拒绝、用户操作反馈、消息提醒、普通连接状态。该选项是可选功能，本轮保留既有通知行为，避免未经确认改掉消息通知交互。

### P2：大字体、横屏与桌面键盘的验证覆盖仍不完整

对话框已有大字体和键盘遮挡测试；本轮增加了矮屏表情面板、桌面附件入口测试。但聊天列表、附件面板固定高度、消息详情、所有设置卡片还没有完成 200% 字号、320 DIP 窄宽以及桌面键盘焦点的系统验证。固定尺寸本身不是违规，需要实际确认是否造成截断、溢出或无法操作。

建议添加代表页面的约束测试，复用 Flutter 的触摸目标、标签和文字对比度检查；在 Android 跑 TalkBack、锁屏恢复、相机取消及“不要保留活动”流程，在 Linux 验证 Tab/Shift+Tab、Enter、Escape 和窗口缩放。没有这些结果前，不宣称全部符合设计或无障碍规范。

## 验证边界

生命周期测试覆盖权限窗口短暂失焦、相机/锁屏暂停、桌面最小化、重复 resumed、保留连接的存活检查、认证失效中止恢复和正在握手时不重复连接。提示测试覆盖普通离线无自动弹窗、令牌拒绝优先、统一中性提示、按钮撤销及不挤动页面；布局测试覆盖表情面板在矮屏上的初始化和拖动。

当前未连接 ADB 真机。运行中的 Mac 后端是 0.86.0，源码是 0.87.0；本轮没有替换已安装的后台进程，也没有打包、公证或发布。

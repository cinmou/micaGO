# Flutter 客户端

Flutter 客户端用于 Android 和 Linux。iOS、macOS 和 Windows 工程目录的存在不等于这些端已有同等验收；Windows 产品使用独立 WinUI 客户端。

## 主要位置

| 位置 | 内容 |
| --- | --- |
| `lib/core/app_controller.dart` | 配对、线路、同步、设备与全局状态 |
| `lib/core/network/` | REST、WebSocket、偏好同步、通知 |
| `lib/core/storage/` | 凭据、SQLite、媒体缓存 |
| `lib/features/chats/` | 消息模型、线程与媒体界面 |
| `lib/core/ui/` | 共用弹窗与提示 |
| `lib/core/l10n/app_localizations.dart` | 英文、简体和繁体字符串 |

## 凭据与生命周期

Android 最低 API 24。凭据保存允许慢速 Keystore 初始化；兑换后保存失败时，重试使用内存中已发放的凭据，不能重复消费邀请。

Keystore 探测失败后只有用户明确选择才启用软件加密存储。随机 keyset 与密文放在不参与系统备份的目录中；这不能防御 root。两种存储在解绑、撤销时都清理，不从旧明文设置回退。

回到前台时先检查已保留的鉴权连接，再决定重连和 delta 补齐。仅仅失去焦点或弹出权限窗口不应打断健康连接。较早的历史请求或探测结果不能覆盖后来的会话、线路和前台状态。

原生 WebSocket 使用协议 ping 与握手超时。重连探测串行，不能用定时器替换正在进行的握手；凭据被拒绝后停止自动重连。

## 聊天与媒体

扫码和粘贴只接受 v4 安全邀请，旧 v1–v3 邀请需要在 Mac 重新生成；已有连接配置的读取和迁移保留。两种入口共用 `saveAndActivate`，随后由线路选择与 delta 补齐启动同步。扫码不再逐个聊天预热缓存，也不再单独选择 LAN/Public 模式。

收到消息只摄取数据；打开线程负责推进已读，见[未读](../features/unread.md)。临时气泡确认后保留展示身份，服务端媒体覆盖本地预览，见[消息](../features/messaging.md)和[媒体](../features/media.md)。

历史用服务端统一的游标分页，刷新保留已经加载的行。图片在上传前后保持比例框；输入框跟随键盘 inset，不通过多层动画补位置。

Linux 附件入口使用文件或照片。不要请求移动图库权限或提供不支持的系统相机入口。异步选择完成后先检查组件是否仍挂载。

Linux 连接页只提供粘贴连接 JSON，不显示当前插件未实现的摄像头扫码入口。通知设置隐藏 FCM 状态，通知诊断保留设备注册结果，隐藏 Android 专属的 FCM、保活、通知权限与通知操作字段；应用内提醒和服务器通知正文设置仍保留。

Linux 应用图标复用默认蓝紫笑脸 SVG，使用透明背景和桌面留白。`tool/generate_linux_icons.py` 使用开发工具 `rsvg-convert` 生成 `linux/icons/hicolor/` 的 SVG 与 16–512px PNG，不增加运行时依赖。构建将图标放入 bundle 的 `data/icons/hicolor/`，窗口直接读取 bundle 图标；菜单与 Wayland 任务栏使用 `com.micago.message.mica_go` 图标名和同名 desktop 文件。desktop 模板随包放在 `share/applications/`，安装时将 Exec 指向实际可执行文件（或将 mica_go 加入 PATH），并将图标复制到用户或系统的 hicolor 主题目录。

Linux 输入框固定显示表情按钮，录音入口放在加号弹出菜单中。加号提供“选择文件”和“录音”两项，文件使用 GTK 原生多选窗口。Linux 主题下加号使用高对比文字色，普通文字优先使用系统 `sans-serif`，缺失字形再回退到 Noto Color Emoji，避免数字和标点使用 emoji 字体。输入框使用 Enter（含数字键盘 Enter）发送，Ctrl+Enter 在光标或选区处换行；按住快捷键不重复发送，输入法仍在组合文字时不发送。快捷键与发送按钮共用可发送状态。Linux 应用窗口显示 micaGO，GNOME 使用 GTK header bar，KDE 等其他桌面使用窗口管理器装饰（包括 Wayland）。重复从启动器打开时激活已有窗口；单实例依赖桌面会话的 D-Bus，Wayland 下窗口前置仍由桌面环境决定。默认关闭主窗口即退出应用。通用设置提供“关闭窗口后常驻系统托盘”开关，默认关闭，偏好保存在本机 `micago.linux.trayEnabled`。开启后通过 AppIndicator / Ayatana 显示托盘图标，关闭主窗口时隐藏到托盘，托盘菜单提供打开与退出。Ctrl+Q 和设置中的退出始终结束应用。系统托盘不可用时关闭窗口会退出，托盘服务消失时恢复已隐藏的窗口。Linux 构建需要 `appindicator3-0.1` 或 `ayatana-appindicator3-0.1` 开发库，Ubuntu CI 安装 `libayatana-appindicator3-dev`。

Linux 会话和消息通过右键或菜单键 / Shift+F10 打开操作菜单。列表不启用滑动标读、隐藏或拖拽未读徽标。搜索栏默认收起，点击搜索按钮或按 Ctrl+F 展开，Escape 或关闭按钮收起并清空筛选。刷新按钮随搜索栏显示，焦点在列表内时支持 F5。消息文字可以鼠标拖选，时间通过悬停提示查看，不依赖横拖。图片查看提供翻页按钮、左右方向键和 Escape。共享 bottom sheet 在 Linux 使用带关闭按钮的桌面对话框；其他平台继续使用原有面板和手势。

Linux 设置通过齿轮按钮打开独立 GTK 窗口，重复点击激活已有窗口，关闭设置窗口释放对应视图。该窗口复用主窗口的 Flutter 引擎与控制器，外观、字体和联系人修改即时共享。通过 `runWidget` / `ViewCollection` 管理视图，主聊天窗口按自身焦点判断通知前台状态。设置以通用、外观、消息显示、通知、联系人、数据管理和关于分类呈现，窄窗口使用分类下拉选择。分类内容复用原有设置组件。

Linux 外观页的主题模式提供跟随系统、浅色和深色。颜色列表隐藏系统动态配色，旧的系统配色值按 micaGO 配色读取。专属的“Linux”主题参考 KDE Breeze 的冷灰表面与蓝色重点，提供紧凑按钮和小圆角，仅在 Linux 的配色列表中可选。其他平台读取该配色值时回退到 micaGO。

Linux 外观页提供 85%–130% 本机字号缩放，叠加系统辅助字号，不覆盖系统缩放；偏好保存为 `micago.linux.textScale`。桌面使用稍紧凑的控件密度、56px 会话栏标题和默认 320px 侧栏，侧栏宽度独立保存在 `linux_sidebar_width`，外观设置内容限制宽度。Linux 字号与侧栏宽度是本机偏好，不进入设置备份。其他平台的字号、布局和偏好键不变。

Android 系统通知和 FCM 后台引擎复用相同通知模型、原生插件与 SQLite 缓冲，见[通知](../features/notifications.md)。系统头像和锁屏操作仍需实机检查。

## 界面与语言

其他平台的设置中，单个开关直接操作，关闭时不附加解释段落；外观、消息显示等多项设置才进入子页。通讯录匹配直接放在“通用”中，权限被拒绝时原地提供系统设置入口，不再保留单独的联系人页。Linux 使用本地 vCard 导入入口，通过设置窗口所属的 GTK 原生文件对话框选择文件，后台流式读取 UTF-8 `.vcf`，不设置固定文件大小门槛，复用现有纯 Dart 解析器。逐张处理姓名、身份、电话、邮箱、头像及结构字段，内嵌头像先写入临时目录。逐张解析，跳过异常或无可用地址的记录并报告数量，全部无效时保留已导入数据。支持 CR / LF 换行、折行和 quoted-printable 软换行。保存姓名、电话、邮箱和内嵌头像，复用现有头像显示入口。头像由 Flutter 解码为最长边 256px 的 PNG，按内容哈希存入 `linux-contact-avatars` 并在 JSON 中记录文件名。损坏头像单独提示并保留原头像和联系人资料，未带头像的更新保留已有头像。重新导入后清理旧图片，清除联系人同时删除图片目录。不调用系统通讯录权限。UID 经过 SHA-256 形成身份；无 UID 时复用已有电话/邮箱匹配，同批重叠记录和重复导入维持身份，不按姓名合并。数据原子写入应用支持目录的 `linux-contacts.json`，启动时重建现有 ContactIndex，清除入口删除导入文件和本机匹配。导入联系人不包含在设置备份中。聊天详情负责当前聊天的名字、头像、静音和发送账号；“隐藏的聊天”管理会话可见性，与通讯录匹配分开。

Material 弹窗与 bottom sheet 默认行为集中在 `core/ui/app_dialog.dart`；配对弹窗共用 `pairing_dialogs.dart`。普通断线使用顶部连接提示，不弹阻塞弹窗；凭据被拒绝才进入终止配对流程。

REST 请求共用传输、状态码和 JSON 错误处理。API 失败抛出 `ApiException`，后台刷新在调用处保留已有状态；主动修改设置向界面报告具体失败。

非模态通知共用 TopBanner；隐藏操作的 Undo 也走同一入口。不要恢复散落的底部 Snackbar 或每页一套 AlertDialog。

三语言表保持 key 一致。主界面使用上下文翻译；后台引擎没有相同的 UI 上下文，不能假定它能直接读取页面 locale。技术诊断字段可以保留英文。

Android 的“设置 → 外观 → 应用图标”提供默认（浅底蓝紫笑脸）、经典（原玻璃笑脸）和简约（深青底 m 气泡）。新安装及尚未选择图标的旧版升级使用默认图标。选择保存在 Android 的组件启用状态中，重启后读取实际状态，不进入设置备份，也不跨设备同步。桌面形状、主题配色和刷新速度由 launcher 决定；系统应用信息等位置仍可显示应用级的默认图标。

三套 launcher `activity-alias` 指向始终启用的 `MainActivity`；主 Activity 同时声明 `MAIN/INFO`，使 `getLaunchIntentForPackage` 优先返回稳定入口，已发通知和会话快捷方式不会指向随后被禁用的图标别名。分享和旧快捷方式仍可直接打开主 Activity。主 Activity 使用 `singleTask` 和应用默认 task affinity，避免从不同图标入口打开多个任务。Android 13+ 批量切换组件状态；旧版先启用目标，再关闭其他图标，失败时尝试恢复原状态。别名名称必须跨升级保留。入口切换、通知/分享返回现有任务、覆盖安装后的选择保留仍需安卓设备验收。

新图标的可编辑源文件在 `MicaGoFlutterClient/tool/launcher_icons/`，`tool/generate_launcher_icons.cjs` 使用开发工具 `sharp` 生成资源和设置页预览，应用不增加运行时依赖。前景包含气泡尾部在内均留在中央 66dp 安全圆内；同时提供单色层和 API 24–25 的静态图标，默认和简约图标使用统一的前景安全区及额外 4% 缩放留白，设置页预览取中央 72dp 区域。经典版保留换图标前的整套安卓资源，预览取原自适应前景的中央 72dp 区域；生成脚本不重新合成或缩放经典版正式资源。

开发者工具保留测试聊天、实时事件、当前设备注册和通知诊断。实时页面直接展示数据，同时监听连接与应用状态；设备诊断读取实际缓存计数，不展示旧预热流程的计数。导出设置直接选择保存位置，导入仍需确认覆盖范围。消息显示页的简短说明放在所有选项下方。

## 备份与检查

`.micagobak` 是设置 ZIP，包含允许导出的外观、偏好、推送服务选择和自定义图片，不包含设备凭据、聊天历史、推送令牌或待同步操作队列。恢复设置不能替代配对：未配对时恢复会提示仍需配对；已配对时若推送服务选择改变，会按新选择为本机重新注册推送。`BackupService` 中每个 SecureStore 键都要列入 `backedUpKeys` 或 `localOnlyKeys`，新增键未归类时测试失败。

[backup_service.dart](../../MicaGoFlutterClient/lib/core/backup/backup_service.dart) 是导出范围的依据；[测试目录](../../MicaGoFlutterClient/test) 覆盖配对、线路、发送确认、通知、布局和状态同步。构建与命令见[开发](../DEVELOPMENT.md)。

线程展示列表按消息集合和隐藏状态缓存，页面重建复用列表身份。Linux 设备注册使用 `linux` 平台值，旧 `unknown` 设备后续注册时更新。

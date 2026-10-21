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

收到消息只摄取数据；打开线程负责推进已读，见[未读](../features/unread.md)。临时气泡确认后保留展示身份，服务端媒体覆盖本地预览，见[消息](../features/messaging.md)和[媒体](../features/media.md)。

历史用服务端统一的游标分页，刷新保留已经加载的行。图片在上传前后保持比例框；输入框跟随键盘 inset，不通过多层动画补位置。

Linux 附件入口使用文件或照片。不要请求移动图库权限或提供不支持的系统相机入口。异步选择完成后先检查组件是否仍挂载。

Android 系统通知和 FCM 后台引擎复用相同通知模型、原生插件与 SQLite 缓冲，见[通知](../features/notifications.md)。系统头像和锁屏操作仍需实机检查。

## 界面与语言

Material 弹窗与 bottom sheet 默认行为集中在 `core/ui/app_dialog.dart`；配对弹窗共用 `pairing_dialogs.dart`。普通断线使用顶部连接提示，不弹阻塞弹窗；凭据被拒绝才进入终止配对流程。

非模态通知共用 TopBanner；隐藏操作的 Undo 也走同一入口。不要恢复散落的底部 Snackbar 或每页一套 AlertDialog。

三语言表保持 key 一致。主界面使用上下文翻译；后台引擎没有相同的 UI 上下文，不能假定它能直接读取页面 locale。技术诊断字段可以保留英文。

## 备份与检查

`.micagobak` 是设置 ZIP，包含允许导出的外观、偏好和自定义图片，不包含设备凭据、聊天历史、推送令牌或待同步操作队列。恢复设置不能替代配对。

[backup_service.dart](../../MicaGoFlutterClient/lib/core/backup/backup_service.dart) 是导出范围的依据；[测试目录](../../MicaGoFlutterClient/test) 覆盖配对、线路、发送确认、通知、布局和状态同步。构建与命令见[开发](../DEVELOPMENT.md)。

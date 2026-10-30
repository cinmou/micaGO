# 通知与推送

## 送达路径

客户端在线时可通过 WebSocket / delta 得到消息，再显示本地通知。Android 可选保活服务维持后台连接，也可选用自己的 Firebase 项目接收 FCM 数据推送。这些功能默认关闭，系统省电策略仍可能限制后台运行。

FCM 传递数据，由客户端生成本地通知；消息历史继续通过 micaGO API 同步。前台实时连接已经处理的消息不应再弹一份 FCM 通知。FCM 与其他路径需要去重，不能把同一消息显示两次。

Windows 运行时通过自己的实时连接显示原生通知，不依赖 FCM。没有正在维护的 iOS 推送能力；其他平台不能直接套用 Android 后台行为。

服务端支持 `none`（关闭）、`webhook` 和 `fcm`。HMS、Harmony Push、ntfy 的未实现占位已移除，新配置和设备注册不接受这些渠道；旧配置中的 `hms` 段会被忽略，废弃的默认渠道回退为 `none`。FCM 未配置或服务账号无效时不列为可用投递渠道。

## 会经过 Google 的数据

通知预览设置决定 FCM 载荷是否包含发送者和正文：仅发送者、发送者和消息、或不显示内容。选择发送者和正文，就不能再宣称消息内容从不经过 Google。

服务账号私钥留在 Mac。手机取得的是 Firebase 客户端配置和它自己的推送令牌。推送令牌用来寻址 Google 的设备投递服务，也记录在 Mac 的设备注册表中。

Google 服务账号使用 `cloud.google.com/go/auth` 的 2LO provider 签名并换取 OAuth access token，FCM 与 Firestore 共用库提供的缓存，到期前一分钟按需刷新。换令牌沿用调用方的取消信号和 HTTP 超时，不自动搜索环境中的其他凭据。SDK 的请求/响应调试日志始终关闭；对外只展示错误状态，保留取消、超时和 HTTP 错误的原始类型，不展示断言、令牌或 Google 原始错误正文。

可选 Firestore 功能只写公网 URL，不写聊天历史、设备凭据或附件。当前客户端没有完整的 Firestore URL 自动发现流程，不承诺打开它就能自动找回变化后的地址。

安装和常见故障统一见 [Firebase 设置](../setup/firebase/README.md)。

## 头像和原生样式

Android 使用系统 `MessagingStyle`，按会话叠放消息，发送者用 `Person` 区分。Android 11 及以后可关联 long-lived conversation shortcut。头像来自本地联系人或用户设置；群聊头像和每位发言者头像不能混用。

没有头像时交给系统回退。通知模板、折叠方式、头像尺寸由系统和 OEM 决定，不维护第二套自绘通知。不同 Android 版本视觉不同，不能仅凭外观变化断定投递失败。

通知预览在 SQLite 中按设备与聊天保存，前台和后台引擎共用事务保护。当前每会话最多 6 行、总计 100 会话。解绑或凭据撤销要清除本应用的通知与会话快捷方式。

## 回复和标读

通知操作只携带聊天路线、设备 ID 和必要时间，不携带凭据。后台执行前重新校验当前配对。Flutter 的点击、回复和标读共用 `NotificationTarget` 解析路线、设备身份与标读截止时间。系统里仍保留的旧通知可以按聊天路线打开页面；回复和标读必须携带与当前配对匹配的设备 ID，标读还要求有效的原始消息时间。

回复是普通新消息。结果不确定时不能自动重发。标读只处理通知包含的原始消息截止点，成功后仍要保留新到的通知，见[未读](unread.md)。

## 设置保存

关闭 FCM 保留已导入文件的路径，显式清除配置才移除引用。文件丢失或无效时不应显示已配置。公网 URL 同步、项目 ID 和预览设置需从服务端回填，同时保留用户尚未保存的编辑。

## 实现与验证

- 服务端：[notify](../../MicaGoServer/micago-server/internal/notify)、[notification_status_test.go](../../MicaGoServer/micago-server/internal/httpapi/notification_status_test.go)。
- Flutter：[push_service.dart](../../MicaGoFlutterClient/lib/core/network/push_service.dart)、[notification_display.dart](../../MicaGoFlutterClient/lib/core/network/notification_display.dart)、[micago_conversations](../../MicaGoFlutterClient/packages/micago_conversations)。
- 测试：[notification_display_test.dart](../../MicaGoFlutterClient/test/notification_display_test.dart)、[notification_reply_test.dart](../../MicaGoFlutterClient/test/notification_reply_test.dart)、[通知相关测试目录](../../MicaGoFlutterClient/test)。

实机要检查后台、锁屏、冷启动、头像、展开、点击定位、回复、标读和撤销配对。FCM 接口返回成功只说明请求被接收，不代表手机已经显示通知。

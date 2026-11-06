# 0005：Android 推送改用 UnifiedPush（Web Push）

日期：2026-11-06。状态：待确认（demo 分支 `feat/unifiedpush-demo`；motorola edge 40 pro 实机：ntfy 与 embedded FCM 在后台和进程被杀时均显示通知）。

现有 Android 推送依赖用户自建 Firebase 项目：Mac 导入 `google-services.json` 与服务账号私钥，FCM 载荷按预览设置可能包含发送者和正文，经过 Google 时是明文。设置成本高，私钥长期留在 Mac，“发送者和正文”与“内容不经 Google”只能二选一。

选择：服务端新增 `unifiedpush` 渠道，按 RFC 8030 发送 Web Push，用 RFC 8291 aes128gcm 加密到设备公钥，用 RFC 8292 VAPID 签名。VAPID P-256 私钥首次加载时生成，单独存放在 `~/.micago/vapid_private_key.pem`（0600），不写入 config.yaml，也不需要用户配置。走哪条推送服务由手机决定：已安装的 distributor（ntfy、NextPush、Sunup…），或 app 内置的 embedded FCM distributor；后者带 VAPID 直接注册 Google Play 服务的原生 Web Push 端点，不需要 Firebase 项目或 gateway。推送服务只看到密文、时间和大小。

代价：

- 设备注册的 pushToken 变为 `{endpoint,p256dh,auth}` JSON；endpoint 是能力 URL，日志、错误和 API 只暴露 host。
- Mac 会向设备提供的地址发 POST。只接受 https、不跟随重定向；不封私有地址，因为自建 ntfy 常在局域网内。
- 用户选 ntfy 时，Mac 与手机都必须连得到同一个 ntfy；ntfy.sh 要求先有订阅者，且只把 `up` + 12 字符的主题视为 UnifiedPush 主题（来自 ntfy 源码）。
- 被杀后台收推送时，connector 以默认入口启动无界面引擎，会执行完整 `main()`；比 FCM 独立 isolate 重。
- `unifiedpush` Flutter 插件是联邦插件，会把 `unifiedpush_linux` 及其 `window_manager` 等依赖带进 Linux/Windows/macOS 构建。
- 更换 VAPID 密钥会令全部订阅失效，需要设备重新注册；demo 未做自动处理。
- embedded FCM distributor 与 `firebase_messaging` 同时接收 c2dm 广播。进程被杀时 firebase_messaging 可能先启动其后台引擎，UnifiedPush 插件挂到该引擎而不执行 `main()`，推送被丢弃（实机复现）。现由 Firebase 后台处理器同样初始化 UnifiedPush 规避；若删除 firebase_messaging，此问题随之消失。

旧的 Firebase 路径在 demo 中保留为“Legacy”并可共存；是否删除 Firebase 依赖、Firestore 公网 URL 同步和 `/api/fcm/client`，待维护者决定。

考虑过的替代：只加 ntfy 明文发布（无加密，依赖 ntfy 认证）；继续只用 FCM 并把正文移出载荷（无法同时显示预览且不经 Google）。两者都不能在“显示正文”时避开推送服务读取内容。

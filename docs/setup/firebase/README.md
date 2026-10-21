# Android 推送设置：Firebase / FCM

FCM 是可选功能，使用你自己的 Firebase 项目。先完成正常配对和聊天收发，再配置推送。Windows 不需要 FCM。

## 准备两个文件

1. 在 [Firebase Console](https://console.firebase.google.com/) 创建或选择项目。
2. 添加 Android 应用，包名填写 `com.micago.message.mica_go`，下载 `google-services.json`。
3. 在项目设置的服务账号页面生成服务账号 JSON 私钥。它只由 Mac 后端使用，不放进手机。
4. 确认项目启用了 Firebase Cloud Messaging API。服务账号需要发送权限；`roles/firebasecloudmessaging.admin` 包含 `cloudmessaging.messages.create`。不要为了省事授予 Owner。

两个文件必须来自你要使用的项目。Android 注册步骤见 [Firebase Android 配置](https://firebase.google.com/docs/android/setup)，服务端权限见 [FCM HTTP v1](https://firebase.google.com/docs/cloud-messaging/send/v1-api)。micaGO 在运行时读取客户端配置，普通用户不需要为此重编 APK。

## 在 Mac 保存并配置

把文件放到不会随手清空的位置，例如 `~/.micago/`。建议客户端配置文件名为 `google-services.json`。服务账号文件包含私钥，不上传仓库或 issue。

Companion → 通知：启用通知和 FCM，分别选择两个文件，选择通知预览，再保存。文件需要持续保留；应用保存路径，不会把文件导入到一个独立的配置仓库。关闭 FCM 会保留路径，显式清除配置才移除引用。

客户端下一次初始化推送时会从已鉴权 API 获取 Firebase 客户端配置，向 Google 取得推送令牌，再注册到 Mac。Android 13 及以后还需要系统通知权限。

## 验证

检查 Companion 的客户端配置和服务账号是否有效，再检查设备是否注册为 FCM 已启用。发送测试请求用于检查服务端链路；不要仅凭“发送成功”判断手机已显示通知。

让手机退出当前聊天并进入后台，通过自己控制的测试会话产生新消息，检查实际系统通知。若有保活，分别测试启用和停用保活的情况，避免把 WebSocket 通知误当成 FCM 验证。

## 隐私

预览选择“发送者和消息”时，名字与正文经过 Google FCM；“仅发送者”不带正文；“无”用于不显示内容的路径。聊天历史和附件仍通过 micaGO 连接同步。

服务账号私钥留在 Mac。手机的推送令牌用于 Google 寻址，并保存在 Mac 的本地设备注册表。不能把 FCM 描述为从不处理消息内容，也不能把普通 HTTPS 传输说成应用层端到端加密。

Mac 联系人可用于本机后端解析名字；客户端本地联系人和自定义头像也可参与通知展示。不要笼统承诺所有名字都只留在某一个进程。

## 可选 Firestore URL 写入

Companion 的公网 URL 同步选项可把 `publicBaseUrl` 写入 Firestore，默认文档为 `server/config`，不写凭据、聊天或附件。它与 FCM 发送是独立用途，默认关闭。

当前客户端没有完整的 Firestore 自动发现流程，打开此开关不能保证地址变化后自动重连。没有明确用途时保持关闭；不要为它设置公开读写规则。

有问题先看[故障排查](troubleshooting.md)。实现与后台操作规则见[通知](../../features/notifications.md)。

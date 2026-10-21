# micaGO Server

Mac 侧有两个组件：[Go 后端](micago-server)读取 Messages 并提供聊天 API，[Companion](micago-mac-companion)管理进程、配对、设置和可选隧道。

开始开发先看[架构](../docs/ARCHITECTURE.md)和[开发说明](../docs/DEVELOPMENT.md)。接口从[API 导航](../docs/reference/api.md)进入，不再按早期版本规格找当前协议。

运行后端：

```sh
cd MicaGoServer/micago-server
go run ./cmd/micago
```

默认本机 HTTP 控制端口为 3000，设备 TLS 端口为 3001。首次运行生成本机配置；设备通过 Companion 的一次性邀请获得独立凭据。安全边界见[连接](../docs/features/connection.md)。

`relay.db` 包含缓存和 micaGO 自己的配对、已读、偏好等状态，不能把整个数据库当成可随手删除的缓存。

同步循环、发送、附件与推送的规则分别见[消息](../docs/features/messaging.md)、[媒体](../docs/features/media.md)和[通知](../docs/features/notifications.md)。

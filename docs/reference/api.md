# API 阅读导航

这页记录接口分工和容易误用的规则。路由是否存在以 [router.go](../../MicaGoServer/micago-server/internal/httpapi/router.go) 为准；JSON 字段以 [store/models.go](../../MicaGoServer/micago-server/internal/store/models.go) 和对应 handler 为准。新增接口时更新相关功能说明，不再追加一个版本规格。

## 鉴权

`GET /api/health` 不需要凭据。`POST /api/pairing/redeem` 使用一次性邀请。普通已配对请求在 Authorization header 中带独立设备凭据。

创建邀请和查询邀请状态需要本机管理员身份。`/api/server/` 的配置修改、列出全部设备、调试消息等操作有额外范围限制；设备可读取自己的状态并修改允许的通知预览。精确权限见 [clientRouteAllowed](../../MicaGoServer/micago-server/internal/httpapi/device_auth.go)，不能把“已鉴权”当作管理员。

## 常用接口

| 用途 | 路由 |
| --- | --- |
| 配对 | `POST /api/pairing/create`、`POST /api/pairing/status`、`POST /api/pairing/redeem` |
| 状态和地址 | `GET /api/server/info`、`GET /api/server/status`、`GET /api/server/urls` |
| 聊天列表 | `GET /api/chats` |
| 统一历史 | `GET /api/messages/history` |
| 增量同步 | `GET /api/messages/delta` |
| 发送文本 | `POST /api/chats/{guid}/send` |
| 附件发送 | `POST /api/chats/{guid}/send-attachment`、`POST /api/chats/{guid}/send-attachments` |
| 读取附件 | `GET /api/attachments/{guid}`，以及 `/preview`、`/playable` |
| 消息操作 | `/api/messages/actions/capabilities`；编辑、撤回、删除在具体聊天消息路径下 |
| 已读和手动未读 | `GET` / `PATCH /api/read-state` |
| 隐藏偏好 | `GET` / `PATCH /api/chat-preferences`、`GET` / `PATCH /api/message-preferences` |
| 同步控制 | `/api/sync/settings`、`/api/sync/rules`、`/api/sync/policy`、`POST /api/sync/now` |
| 设备 | `POST /api/devices/register`、设备自身 heartbeat；管理员可以列出与撤销设备 |
| FCM 配置 | `GET /api/fcm/client`；只返回客户端配置，不返回服务账号 |
| 通知设置 | `POST /api/server/notifications`、`PATCH /api/server/notifications/preview`、`POST /api/server/notifications/test` |

具体方法、查询参数和错误码必须在修改前读 handler，不从这张缩写表生成请求。

## 不要混用的游标与身份

历史接口用重复的 `chatGuid` 查询参数指定路线，`limit` 默认 100、上限 500，最多 32 条路线，返回不需要客户端解析的 cursor。客户端原样保存、传回 cursor，不自行拼日期游标。

Delta 游标用于新变化，不与历史游标互换。旧的单路线 `/api/chats/{guid}/messages` 仍在路由表中，但不应用它代替统一多路线历史。

消息身份保留聊天 GUID；`tempGuid` 只标识具体待确认发送。HTTP 202 `send_confirmation_timeout` 不能解析为正常收到的新消息，也不能标为确定失败。

已读与隐藏偏好的数据结构包含服务端范围和版本。隐藏批次有 mutation ID 保障重复提交不会重复执行，手动未读使用对应版本保护；客户端队列不能跨服务器复用。

## WebSocket

`/ws` 使用 Authorization header。事件带类型与数据，定义见 [realtime](../../MicaGoServer/micago-server/internal/realtime)。消息事件用于实时更新；偏好/已读变化事件提示客户端重新取状态。

发送链路中的 `send:pending`、`send:match`、`send:error` 要与消息事件区分。事件可能重复或与 REST 响应交错，确认和去重规则见[消息](../features/messaging.md)。

## 错误

大部分 HTTP 错误使用 `{error: {code, message}}`。偏好、已读等接口还会返回特定冲突数据，不能假设所有非 2xx 都有相同 JSON 外壳。看 handler 和对应测试。

已鉴权的 401 是凭据拒绝，普通操作的 403 是权限不足。超时或断连不代表发送没发生，不自动重试可能造成重复消息的操作。

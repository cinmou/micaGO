# 连接协议与凭据安全

## 配对格式

客户端兼容三代配对 JSON。

v1：

```json
{
  "baseUrl": "http://192.168.1.20:3000",
  "websocketUrl": "ws://192.168.1.20:3000/ws",
  "token": "<redacted>"
}
```

v2：

```json
{
  "version": 2,
  "mode": "lan_first",
  "token": "<redacted>",
  "serverName": "Mac mini",
  "endpoints": [
    { "kind": "lan", "baseUrl": "http://192.168.1.20:3000", "priority": 1 },
    { "kind": "public", "baseUrl": "https://go.example.com", "priority": 2 }
  ]
}
```

v3：

```json
{
  "version": 3,
  "token": "<redacted>",
  "serverName": "Mac mini",
  "configRevision": "revision-value",
  "candidates": [
    { "kind": "lan", "baseUrl": "http://192.168.1.20:3000" },
    { "kind": "public", "baseUrl": "https://go.example.com" }
  ]
}
```

解析器会拒绝缺失 token、无有效 HTTP(S) 地址和非法 WS(S) 地址的内容。v2/v3 中标记为 `hidden`、`isHidden`、`disabled` 或 `enabled:false` 的地址会被过滤；`local`/loopback 候选不会作为远端 Windows 客户端线路。

## 线路选择

每个候选必须连续通过：

1. `GET /api/health`，响应必须为 HTTP 200 且 JSON 中 `ok` 为 `true`。
2. `POST /api/auth/check`，请求头为 `Authorization: Bearer <token>`，响应必须为 HTTP 200。

同组 LAN 地址并行检查，按完成 health+auth 的总耗时选择最快线路。LAN 组没有可用结果时才进入 Public 组。`lan_only` 和 `public_only` 会严格限制候选种类。单个候选超时为 6 秒。

客户端不会把 token 放进 URL、query string、异常消息或普通配置。WebSocket 将来应优先继续使用 Authorization header；只有平台 API 明确不支持 header 时才考虑服务端已有的 query token 兼容路径。

## 持久化

普通配置路径：

```text
%LOCALAPPDATA%\micaGO\connection-profile.json
```

内容包括服务器名、活动 REST/WS URL、连接模式、配置 revision 和所有候选线路，不包括 token。

token 保存为 Windows Credential Manager 通用凭据：

```text
Target: micaGO.Windows/server-token
User: 当前 Windows 用户
Persistence: Local machine
```

保存时托管和非托管临时字节都会在调用后清零。Disconnect 会删除配置文件和凭据。

## 当前 API

已接入：

- `GET /api/health`
- `POST /api/auth/check`
- `GET /api/chats?limit=250`
- `GET /api/chats/{guid}/messages?limit=50&offset=0&includeEmpty=false`
- `POST /api/chats/{guid}/send`

发送正文：

```json
{
  "tempGuid": "client-generated-guid",
  "message": "text"
}
```

尚未接入 `/api/server/urls` 自动刷新、设备注册/heartbeat、WebSocket、delta 和附件接口。

## 安全规则

- 禁止把配对 JSON、Authorization header 或 token 写入日志、截图、Issue 和测试 fixture。
- 测试文档只能使用 `<redacted>` 或明显无效的 `secret` 占位值。
- 禁止为了排查 Public 地址而关闭 TLS 证书验证。
- 诊断信息可以包含 base URL、HTTP 状态和耗时，但不能包含请求头。
- 后续引入 SQLite 时，token 仍不得进入数据库。


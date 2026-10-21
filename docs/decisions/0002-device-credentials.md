# 0002：一次性邀请与独立设备凭据

状态：现行。整理日期：2026-10-21。

## 背景与选择

旧的共享令牌不能单独撤销一台设备，也不应放进长期可用的二维码。当前 v4 配对码只是一份 5 分钟、单次使用的邀请；兑换后，每台设备得到自己的凭据。

本机管理员凭据留在 Mac。服务端保存设备凭据哈希，撤销设备时关闭它的鉴权连接。LAN 校验证书指纹，公网验证系统信任链，不自动退回明文。

## 代价

旧共享令牌客户端需要重新配对。丢失 TLS 身份或设备凭据后需要恢复或重新授权；长期会话不能靠保存过期配对码恢复。

## 替代方案

共享密码与可重复二维码都不能提供现有的独立设备撤销边界。后续浏览器登录或密码功能需要新授权设计，不能直接延长邀请时限。

证据：[device_auth.go](../../MicaGoServer/micago-server/internal/httpapi/device_auth.go)、[credentials.go](../../MicaGoServer/micago-server/internal/relaydb/credentials.go)。当前规则见[连接](../features/connection.md)。

# 连接与配对

## 第一次连接

Companion 创建 v4 配对邀请，内容包括可用的 LAN / Public 地址、服务端证书 SHA-256 指纹，以及有效期 5 分钟的一次性配对码。不包含本机管理员凭据。

客户端通过 HTTPS 调用 `POST /api/pairing/redeem`。服务端原子消费邀请，发放独立设备 ID 和凭据；数据库只持久保存设备凭据的哈希。设备删除后凭据被撤销，其已连接 WebSocket 也会关闭。

已使用、过期或作废的二维码不能继续配对。Companion 隐藏它，只有用户主动生成才替换邀请。配对之后，应用保存设备凭据，正常重连不需要新的二维码。

## 两个端口

| 默认地址 | 用途 | 校验方式 |
| --- | --- | --- |
| `http://127.0.0.1:3000` | Companion 和本机反向代理 | 本机管理员或设备凭据，按接口限制授权 |
| `https://Mac局域网地址:3001` | 设备直接连接 | 设备凭据与配对证书指纹 |
| 用户设置的公网 HTTPS URL | 外网连接，经用户的代理或隧道 | 设备凭据与系统证书信任链 |

设备 TLS 端口是配置端口加一，最低 TLS 版本为 1.2。HTTP 不对局域网开放。不要通过关闭证书校验或退回明文来解决连接失败。

REST 和原生 WebSocket 都在 `Authorization: Bearer …` 中传递凭据。URL 查询参数令牌和 `--disable-auth` 已移除。仓库里的 Web 构建相关代码不代表目前有可用、安全配对的网页客户端。

## 线路如何选择

配对数据可以携带多个 LAN 地址以及可选的公网地址。隐藏某个 LAN 地址只影响候选地址，不会改变后端监听范围。

Flutter 自动模式下通常先尝试 LAN，在蜂窝网络会优先公网候选；连续的多个 LAN 候选会并行探测。用户手选的线路先单独尝试，失败后才回到自动选择。较早的探测结果不能覆盖用户后来发起的切换。

Windows 也通过健康检查和鉴权探测可用线路，支持手动切换和公网回退。两端共享信任规则，具体网络探测实现各自维护，不能假定每个超时参数完全一致。

线路选择只决定“怎么到达服务端”。聊天发送路线决定“用哪个电话或邮箱账号发送”，这两个概念不能混用。

## 凭据失效

服务端只有在设备凭据不存在或已撤销时返回 401；权限不足返回 403，查询凭据时数据库等临时错误返回 503。设备凭据没有自动到期时间。

Flutter 只把带 `error.code = unauthorized` 的 micaGO 401 识别为凭据拒绝，不根据代理的 HTML 登录页清除配对。已确认线路上的真实拒绝会终止该凭据会话；备用地址探测只更新线路状态。重连时先尝试其他候选，只有完整候选集全部明确拒绝时才清除配对；超时、DNS 失败或 503 保留配对等待重试。设备注册只发送到已确认可用的当前线路，旧线路的迟到失败不能撤销新线路。

Flutter 后台通知操作可能使用较早保存的线路，失败时不自行删除配对；回到前台后由统一线路选择确认。消息发送仍不自动重试，避免重复发送。

Android 默认用 Keystore 保存凭据。部分设备 Keystore 无法工作时，只能经用户明确选择改用软件加密存储；不能自动回退到明文。Windows 用 Credential Manager，普通连接配置文件不包含凭据。Linux 的存储行为需要在目标桌面环境核对。

客户端设置备份不携带设备凭据和待同步操作队列。恢复设置后仍需建立有效配对。

## 边界

Web/PWA、Telegram 入口和密码连接尚未作为当前产品协议提供。若要新增，应先单独设计授权与撤销流程，不能直接复用手机凭据或延长一次性配对码。

## 实现与验证

- 服务端：[device_auth.go](../../MicaGoServer/micago-server/internal/httpapi/device_auth.go)、[device_auth_test.go](../../MicaGoServer/micago-server/internal/httpapi/device_auth_test.go)。
- Flutter：[connection_candidate.dart](../../MicaGoFlutterClient/lib/core/network/connection_candidate.dart)、[app_controller.dart](../../MicaGoFlutterClient/lib/core/app_controller.dart)、[pairing_payload_test.dart](../../MicaGoFlutterClient/test/pairing_payload_test.dart)。
- Windows：[ConnectionManager.cs](../../MicaGoWindowsClient/src/micaGO.Infrastructure/Connection/ConnectionManager.cs)、[契约测试](../../MicaGoWindowsClient/tests/micaGO.Core.ContractTests)。

测试不能替代真实设备上的断网、换网、证书变化和撤销设备验收。操作步骤见[手动检查](../manual-test-flow.md)。

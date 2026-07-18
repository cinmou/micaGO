# 功能完成度

更新时间：2026-07-18。

“代码完成”表示源码路径已经实现；“Windows 待验证”表示尚未通过 Windows 编译或运行，不能视为验收通过。

| 模块 | 状态 | 当前内容 | 下一步 |
| --- | --- | --- | --- |
| WinUI 3 工程 | 代码完成，Windows 待验证 | .NET 10、WinAppSDK 2.2、x64/ARM64、unpackaged | 首次 Windows 编译并修正项目/XAML 问题 |
| Mica 和标题栏 | 代码完成，Windows 待验证 | MicaAlt、能力检测、Windows 10 回退 | 实机检查浅色/深色/高对比度 |
| 配对 JSON | 代码完成，Windows 待验证 | v1/v2/v3、隐藏地址过滤、URL 校验 | 使用真实 Companion JSON 验收 |
| LAN/Public 选择 | 代码完成，Windows 待验证 | 多 LAN 并行 health+auth、最快线路、Public 回退 | 增加逐线路诊断和手动固定线路 |
| 凭据安全 | 代码完成，Windows 待验证 | Windows Credential Manager，配置不含 token | Windows 上检查写入、恢复和删除 |
| 会话列表 | 基础代码完成 | 真实 `/api/chats`、搜索、服务类型、置顶/静音显示 | 本地缓存、未读 watermark、操作菜单 |
| 历史消息 | 基础代码完成 | 每会话最新 50 条、服务端 newest-first 转时间顺序 | 上拉分页、取消旧请求、复杂消息语义 |
| 文本发送 | 基础代码完成 | `/send` 确认后加入列表 | 乐观气泡、失败状态、重试、tempGuid 对账 |
| WebSocket | 未开始 | 无 | Authorization header、重连退避、前后台生命周期 |
| delta 补漏 | 未开始 | 无 | cursor 持久化、循环拉取、GUID 去重 |
| SQLite | 未开始 | 无 | chats/messages/attachments/settings schema 与迁移 |
| 未读/置顶/静音/隐藏 | 部分 | 读取服务端字段并显示 | 本地状态、watermark、同步规则写接口 |
| 媒体 | 占位 | 消息只显示附件文件名 | preview/playable/original、缓存和查看器 |
| 附件发送 | 未开始 | 无 | 文件选择、上传、进度、批量发送 |
| 通知与托盘 | 未开始 | 设置页仅展示规划项 | AppNotification、点击激活、关闭到托盘 |
| MSIX | 未开始 | 当前 unpackaged self-contained | 连接稳定后加入 x64/ARM64 MSIX |
| 自动化测试 | 部分 | 5 个 Core 配对契约测试，尚未运行 | Windows CI、API fake、ViewModel 与 UI 测试 |

## 当前可验收的最短闭环

首次 Windows 编译通过后，只验收以下路径：

```text
启动 -> 粘贴配对 JSON -> LAN/Public 探测 -> 保存凭据
     -> 拉取真实会话 -> 打开会话 -> 拉取 50 条消息 -> 发送文本
     -> 重启自动恢复 -> 设置页 Disconnect
```

这条路径稳定之前，不应同时开始托盘、通知或 MSIX。WebSocket 和 SQLite可以开始设计，但接入 UI 前必须先确定去重与 cursor 持久化规则。

## 已知技术风险

- 当前没有 Windows 编译结果，XAML 资源键、WinAppSDK 2.2 API 和 unpackaged 启动仍可能有平台编译/运行问题。
- `ShellPage` 仍是 code-behind，功能继续增加前必须迁移到 ViewModel，否则实时消息和分页会造成竞态。
- 当前历史请求没有按会话取消；快速切换会话时，旧请求可能晚到并写入新会话页面。
- 文本发送尚无乐观消息和失败气泡，网络慢时用户只能等待。
- Credential Manager 使用 Win32 通用凭据，不是 MSIX 身份下的 `PasswordVault`；转 MSIX 时需要决定是否迁移到 Credential Locker，并提供一次性迁移。
- 媒体缓存还未实现；后续必须坚持气泡使用 bounded preview、查看器优先 original 的既有客户端规则。


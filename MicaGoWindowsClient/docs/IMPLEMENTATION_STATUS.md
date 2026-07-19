# 功能完成度

更新时间：2026-07-19。

“代码完成”表示源码路径已经实现；“Windows 待验证”表示尚未通过 Windows 编译或运行，不能视为验收通过。

| 模块 | 状态 | 当前内容 | 下一步 |
| --- | --- | --- | --- |
| WinUI 3 工程 | Debug x64 已验证 | .NET 10、WinAppSDK 2.2、x64/ARM64、unpackaged；VS 2026 + .NET 10.0.302 编译 0 warning/error | 验证 ARM64 和 Release |
| Mica、标题栏与 DPI | Windows 11 暗色已验证 | 原生 caption buttons、低 tint Mica 标题栏/侧栏、独立联系人栏、纯色聊天画布、局部圆角、Per-Monitor V2 | 验证浅色、高对比度和跨显示器切换 |
| 配对 JSON | 代码完成，Windows 待验证 | v1/v2/v3、隐藏地址过滤、URL 校验 | 使用真实 Companion JSON 验收 |
| LAN/Public 选择 | 代码完成，Windows 待验证 | 多 LAN 并行 health+auth、最快线路、Public 回退 | 增加逐线路诊断和手动固定线路 |
| 凭据安全 | 代码完成，Windows 待验证 | Windows Credential Manager，配置不含 token | Windows 上检查写入、恢复和删除 |
| 会话列表 | 已接入 | 真实 `/api/chats`、搜索、SQLite 缓存、Google 名称/头像、多路由联系人合并、本地置顶排序 | 自定义别名与群聊组合头像 |
| 历史消息 | 已接入 | cache-first、50 条分页、切换取消旧请求、服务端页合并后从 SQLite 重建视图 | 将“加载更早”按钮改为纯滚动触发并补加载骨架 |
| 文本发送 | 已接入 | 乐观气泡、失败状态、tempGuid/文本时间窗对账、稳定 presentation key | 文字失败气泡点击重试 |
| WebSocket | 已接入 | Authorization header、重连退避、事件作为 delta catch-up 提示 | 完善前后台生命周期与网络变化监听 |
| delta 补漏 | 已接入 | cursor 持久化、循环拉取、SQLite GUID upsert | 增加 API fake 与乱序压力测试 |
| SQLite | 已接入 | WAL；chats/messages/settings/contacts/hidden_messages | schema 版本迁移与未读 watermark |
| 未读/置顶/静音/隐藏 | 部分 | 本地 read watermark、实时未读递增、当前会话通知抑制、置顶/静音设置 | 已读回执写回、隐藏管理和同步规则接口 |
| 媒体 | 已接入 | 原生图片缩放/前后切换、WinUI 音视频播放、HEVC playable 回退、另存/系统打开、缓存与详情缩略图 | Share Contract、视频加载骨架和完整媒体页筛选 |
| 附件发送 | 已接入 | 文件多选、批量乐观气泡、顺序上传、进度、取消、失败重试、SQLite 重启自动恢复、安全对账 | 后台传输 API（当前随应用生命周期） |
| 通知与托盘 | 已接入 | AppNotification、关闭到托盘、设置持久化 | 通知点击精准打开会话、启动/退出菜单 |
| MSIX | 未开始 | 当前 unpackaged self-contained | 连接稳定后加入 x64/ARM64 MSIX |
| 自动化测试 | 部分 | 8 个 Core 契约测试通过（含 U+FFFC、歧义附件对账、稳定展示标识） | Windows CI、API fake、ViewModel 与 UI 测试 |

## 当前可验收的最短闭环

首次 Windows 编译通过后，只验收以下路径：

```text
启动 -> 粘贴配对 JSON -> LAN/Public 探测 -> 保存凭据
     -> 拉取真实会话 -> 打开会话 -> 拉取 50 条消息 -> 发送文本
     -> 重启自动恢复 -> 设置页 Disconnect
```

这条路径稳定之前，不应同时开始托盘、通知或 MSIX。WebSocket 和 SQLite可以开始设计，但接入 UI 前必须先确定去重与 cursor 持久化规则。

## 已知技术风险

- Debug x64 已完成首次 Windows 编译和 unpackaged 启动；ARM64、Release、浅色/高对比度和跨显示器 DPI 仍未验证。
- `ShellViewModel` 已承接状态与实时同步；页面仍保留 WinUI 事件编排，快速切换会话尚需取消旧请求。
- 乐观消息已有稳定 presentation key；ViewModel 仍需 API fake 压测乱序确认和多批次失败重试。
- Credential Manager 使用 Win32 通用凭据，不是 MSIX 身份下的 `PasswordVault`；转 MSIX 时需要决定是否迁移到 Credential Locker，并提供一次性迁移。
- 媒体缓存已落盘且可从设置清理；后续需加入内存 LRU 与解码尺寸限制，避免媒体密集会话占用过高。


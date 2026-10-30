# Mac Companion 与后端进程

Companion 是控制界面，不是聊天客户端。它管理自己启动的后端、配对邀请、设备、同步规则、可选推送配置与可选隧道。

## 窗口与菜单栏

窗口统一由 SwiftUI `WindowGroup` 创建，并使用固定场景值标识唯一仪表盘。`openWindow` 在 App 级别注册，不依赖仪表盘内容先显示；隐藏启动尚未创建窗口时，菜单栏也能创建场景。已有隐藏窗口直接恢复，关闭后清除窗口引用再由 SwiftUI 重建。早到的打开请求等待 App 注册完成；不要恢复手写 `NSWindow` 兜底。

窗口识别只认主界面，不把更新或权限窗口当成 Dashboard。关窗继续在菜单栏运行。菜单栏图标用 template rendering，适配系统深浅色。

`serverDisplayState(process:reachable:)` 合并进程状态和 API 可达性，菜单栏和 Dashboard 都使用它，不能各自推断“运行中”。外部进程可达时应显示外部服务，不接管或终止它。

## 后端与隧道

后端重启等待对应子进程实际退出；停止和退出取消待启动的替代进程。旧进程的输出或退出回调不能影响新进程。崩溃自动重启遵循现有退避和次数限制，不因缺少完全磁盘访问权限无限重试。

cloudflared 自己负责网络重试。Companion 仅监督自己拥有的 cloudflared 子进程；意外退出按 2/4/8/16/32/60 秒重试。连接真正注册并持续 60 秒后才重置退避。停止、退出、关闭自动启动或启用“后端停止时停止隧道”都要取消恢复。外部隧道不接管。

更新前只停自有后端，记录恢复标记。Sparkle 安装中止或重启后按标记恢复，不覆盖用户自选二进制，也不替换外部服务。

Companion 最低支持 macOS 13，登录启动直接使用 `SMAppService.mainApp`；界面仍保留授权状态和注册失败提示。配对二维码由可见 LAN 地址和可选公网地址直接生成 v4 邀请，隐藏地址的保存与升级迁移仍由原有流程处理。

## 配置与权限

本机配置在 `~/.micago/config.yaml`，通过本机控制 API 操作。配对凭据与管理员凭据不同，见[连接](../features/connection.md)。

配置文件、管理员凭据和旧格式迁移统一由 Go 后端管理。Companion 直接启动选定的后端，不生成或改写 YAML；后端在访问 Messages 数据库前完成配置加载。首次启动或升级迁移后，Companion 重新读取本机地址和凭据，再连接控制 API。启动地址的界面偏好仍由 Companion 保存，通过 `--addr` 传给自有进程。控制 API 使用该进程实际启动时的端口；修改尚未重启的启动偏好不会切换正在使用的控制地址。

Mac 控制请求统一使用 `APIClient` 的 HTTP 校验和 JSON 解码。HTTP 错误保留状态码及服务端说明，超时、断连、取消和无效响应分别保留原始错误，不能统称为令牌被拒绝。鉴权收到 401 时，仅在本机配置地址或凭据已变化的情况下重读并重试一次。公网探测失败展示实际响应，不根据 403 或 503 推断凭据错误或后端不存在。

同步调试先核对安装包内后端和源码版本。需要开发版时使用 [build-backend.sh](../../MicaGoServer/micago-server/scripts/build-backend.sh)，不要仅修改源码就判断正在运行的服务已有修复。

完全磁盘访问用于读取 Messages，Automation 用于控制 Messages 发送。联系人权限可选；已拒绝后应引导到系统设置，不能反复提供无效授权按钮。

Mac 联系人用于本机名字匹配，也会通过本机控制 API提供名字/地址缓存给本机后端的联系人解析；不能笼统声称这些字段从不离开 Companion 进程。推送是否携带名字由预览设置决定。

消息编辑、撤回、删除依赖可选 IMCore helper 与当前 macOS 能力。探测失败不等于聊天同步不可用。

## 状态与表单

选择 JSON 文件只表示待保存，不以路径非空显示“已配置”。启用 FCM 时，文件可读性、内容和服务账号校验由后端负责；界面采用后端报告的配置状态；保存成功后清空已提交的文件选择，不清除后端保存的文件引用。请求期间的新选择保留。关闭 FCM 不删除文件引用，清除配置才移除引用；保存失败不能提示清除成功。

远端更新的通知设置只覆盖本地未编辑字段。保留用户未保存的修改，尤其不能用旧表单覆盖手机端调整的隐私设置。

隐藏偏好同步分别显示网络离线、HTTP 状态和无效响应；取消请求不覆盖已有提示。版本探测失败只表示版本未知，不能据此断定后端过旧。

同步监控选择最新完成的结果。`pendingTriggerCount` 是沿用的 API 字段名，实际是累计触发次数，不是待执行任务数。服务不可达或鉴权失败时清理旧连接和旧状态展示。

## 代码与检查

[AppModel.swift](../../MicaGoServer/micago-mac-companion/MicaGoCompanion/AppModel.swift) 管理控制状态；[BackendController.swift](../../MicaGoServer/micago-mac-companion/MicaGoCompanion/Services/BackendController.swift) 管理后端；[TunnelController.swift](../../MicaGoServer/micago-mac-companion/MicaGoCompanion/Services/TunnelController.swift) 管理隧道。

构建和脚本见[开发](../DEVELOPMENT.md)。窗口、Dock 图标、隐藏启动、更新恢复与系统权限需要实际在 macOS 检查。

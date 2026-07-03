# micaGO —— 用户文档

[English](index.md) · **简体中文** · [繁體中文](index.zh-Hant.md)

[← 项目 README](../README.zh-Hans.md) · [快速上手](getting-started.zh-Hans.md) · [CHANGELOG](../MicaGoServer/docs/CHANGELOG.md)

---

欢迎 👋 这些指南帮助你配置 Mac 应用、从手机连接,并(可选)从任何地方访问你的 Mac。
micaGO 让你 **自己的** 设备与 **你自己的** Mac 通信 —— 没有 micaGO 云,你的消息只在你的
Mac 和你连接的设备之间。

---

## 📚 指南

- 🚀 **[快速上手](getting-started.zh-Hans.md)** —— 首次配置:你需要准备什么、在哪里找到
  服务器地址和令牌,以及测试每条连接的推荐顺序。
- 📱 **[安卓客户端连接](android-client-connection.md)**(英文)—— 通过局域网或公网地址
  配对安卓应用,以及它支持哪些功能。
- 🌍 **[使用 Cloudflare Tunnel 远程访问](remote-access-cloudflare.md)**(英文)—— 借助
  你自己的域名从家庭网络外访问你的 Mac。隧道是 **外部且可选** 的;micaGO 不内置也不管理它。
- 🔔 **[推送通知](notifications-setup.md)**(英文)—— 可选的自托管 Firebase / FCM 配置
  与安卓通知故障排查。
- 🔥 **[Firebase 配置参考](setup/firebase/README.md)**(英文)—— 同样的可选推送配置,以
  聚焦清单 + 更深入的分步页面呈现。
- ✅ **[手动测试流程](manual-test-flow.md)**(英文)—— 一份可复制粘贴的清单,从零开始确认
  本地、局域网、公网与客户端连通性。

> 部分指南目前仍为英文;`快速上手` 已有简/繁中文版本,其余正在逐步本地化。

---

## 🔐 安全须知

- 你的 **bearer 令牌** 就是服务器的密码。任何同时拥有你的公网地址 **和** 令牌的人都能访问
  你的 Mac —— 请保密。
- 切勿把令牌贴进截图、公开日志、缺陷报告、聊天或 issue 追踪器。
- 任何离开家庭网络的连接都应优先使用 **HTTPS**(Cloudflare 指南会自动给你 HTTPS)。
- 若你认为令牌已泄露,请在 Mac 应用中生成新令牌并重新连接。

---

## 🧭 各部分在哪里

- **Mac Companion** 运行服务器,显示你的局域网 + 可选公网连接信息、已配对设备与诊断。
- **安卓应用** 通过局域网(同一 Wi‑Fi)或可选公网地址配对,同步会话,发送文本 + 附件 +
  语音(以及你开启后的短信),渲染回应/回复/特效/媒体/贴纸/位置,并可选接收推送。
- **远程访问** 使用你自己的域名 + Cloudflare Tunnel(或你选择的其他隧道)。micaGO 不为你
  提供隧道。

> 软件/设计文档与开发历史位于 [`MicaGoServer/docs/`](../MicaGoServer/docs/README.md) ——
> 这里的 `/docs` 指南是给 **使用** micaGO 的人看的。

详情见各指南,构建说明与完整功能列表见 [项目 README](../README.zh-Hans.md)。

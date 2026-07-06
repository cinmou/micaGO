<p align="center">
  <img src="docs/assets/Server.png" alt="micaGOServer" width="120" />
</p>

<div align="center">

# micaGO

[English](README.md) · **简体中文** · [繁體中文](README.zh-Hant.md)

**你的 iMessage、你的 Mac、你的设备。**
*一个自托管的 iMessage 桥接工具。*

*Built with ♥️ for everyone.*

[![文档](https://img.shields.io/badge/%E6%96%87%E6%A1%A3-0064E0?style=for-the-badge)](https://github.com/cinmou/micaGo/blob/main/docs/index.zh-Hans.md)
[![官网](https://img.shields.io/badge/%E5%AE%98%E7%BD%91-007AFF?style=for-the-badge)](https://micago.cinmou.uk)
[![快速上手](https://img.shields.io/badge/%E5%BF%AB%E9%80%9F%E4%B8%8A%E6%89%8B-0A1317?style=for-the-badge)](https://github.com/cinmou/micaGo/blob/main/docs/getting-started.zh-Hans.md)
[![安全模型](https://img.shields.io/badge/%E5%AE%89%E5%85%A8%E6%A8%A1%E5%9E%8B-31A24C?style=for-the-badge)](https://github.com/cinmou/micaGo#-%E5%AE%89%E5%85%A8%E6%A8%A1%E5%9E%8B)
[![远程访问](https://img.shields.io/badge/%E8%BF%9C%E7%A8%8B%E8%AE%BF%E9%97%AE-5D6C7B?style=for-the-badge)](https://github.com/cinmou/micaGo/blob/main/docs/remote-access-cloudflare.md)
[![CHANGELOG](https://img.shields.io/badge/CHANGELOG-B89B5E?style=for-the-badge)](https://github.com/cinmou/micaGo/blob/main/MicaGoServer/docs/CHANGELOG.md)

</div>

---

## 概览

micaGO 让你 **自己的** 安卓手机,通过你 **自己的** Mac,收发你的 iMessage。Mac 上的
一个小巧 Go 服务器读取本机「信息」数据库,提供一套私密、受令牌保护的 API;一个 macOS
菜单栏 **Companion(伴侣应用)** 负责运行并管理它;一个 **Flutter 安卓应用** 通过你的
Wi‑Fi(或你自行控制的可选公网地址)与之配对。你的数据始终只在 **你的** Mac 和 **你的**
设备之间传输。

micaGO 仍处在测试阶段。它会读取 macOS「信息」的内部数据,并需要「完全磁盘访问权限」。
在依赖它之前,请先阅读 [安全模型](#安全模型) 与 [局限性](#局限性)。micaGO 是独立项目。

---

## ✅ 系统要求

- **Mac Companion:** macOS 13 或更新版本,需要已登录 iMessage,并授予「完全磁盘访问权限」
  以读取「信息」数据。
- **安卓客户端:** Android 6.0 或更新版本(API 23+)。客户端包含手机、平板和大屏布局。
- **网络:** 首次设置推荐使用局域网。远程访问是可选功能,需要你自己的公网地址或隧道。

---

## ✨ 你能得到什么

- **自托管。** 桥接服务运行在你的 Mac 上。可选的推送与远程访问使用 **你** 自己拥有
  并配置的服务。
- **会话与消息。** 会话列表、消息线程、回应(tapback)、引用回复、发送特效、贴纸、
  **位置 / 手写 / Digital Touch**,以及内嵌图片/视频与全屏查看器。
- **发送。** 通过 iMessage 发送文本与附件、**语音消息**,以及在你开启后发送短信
  (默认关闭,由服务器设置控制)。
- **实时 + 补齐。** WebSocket 事件用于实时更新,再加上基于游标的 **增量(delta)**
  同步,在应用关闭后填补遗漏。
- **局域网优先。** 会公布多条局域网路由;客户端自动选择可达的一条并允许你固定。可选
  的公网地址(你自己的隧道)可随处访问。
- **联系人匹配。** 在本机做姓名匹配,需选择启用,并保留在本设备上。
- **通知(可选)。** 保活和 FCM 都走客户端本地的 Android MessagingStyle 通知样式。想用
  推送,接上你 **自己的** Firebase 即可。

---

## 🧩 工作原理

```
            ┌──────────────────────── 你的 Mac ────────────────────────┐
            │                                                            │
 信息       │   chat.db ──► 同步循环 ──► relay.db ──► REST + WebSocket   │
 (iMessage) │      ▲                                        │           │
            │      │ AppleScript / 可选的 IMCore 助手        │           │
            │   ┌──┴───────────────┐                         │           │
            │   │  Mac Companion   │  运行并管理服务器                   │
            │   │  （菜单栏应用）  │                         │           │
            │   └──────────────────┘                         │           │
            └────────────────────────────────────────────────┼──────────┘
                                                              │
                       局域网（同一 Wi‑Fi）  ──或──  可选公网地址（你的隧道）
                                                              │
                                                   ┌──────────▼──────────┐
                                                   │      安卓客户端     │
                                                   │   （Flutter 应用）  │
                                                   └─────────────────────┘
```

- **读取路径** —— 服务器将 `chat.db` 单向同步进自己的 `relay.db`,再提供一套小而稳定的
  REST + WebSocket API。客户端通过基于游标的 **增量** 补齐,并通过 socket 获取实时事件。
- **发送路径** —— 文本通过 AppleScript 经由「信息」发送;附件通过 multipart 上传。编辑 /
  撤回 / 删除 使用可选的内置 [IMCore 助手](#-可选功能)。
- **配对** —— Companion 显示包含局域网/公网候选地址与一个 bearer 令牌的二维码 / 连接
  JSON;客户端扫描或粘贴它。

---

## 🔐 安全模型

micaGO 是 **本地优先** 的,设计上让你的数据始终属于你。

| 关注点 | micaGO 如何处理 |
| --- | --- |
| **鉴权** | 每个 API 调用都需要服务器生成的 **bearer 令牌**(`~/.micago/config.yaml`)。任何同时拥有你的地址 **和** 令牌的人都能访问你的 Mac —— 请像密码一样对待它。 |
| **网络** | 默认绑定到你的 **局域网**。公网暴露需你主动开启,且由你负责;任何离开你网络的流量都应优先用 HTTPS。 |
| **你的数据** | 消息从你的 Mac 提供给已配对设备。联系人在本机匹配。 |
| **推送** | 若你启用 FCM,负载携带用于通知投递的小型唤醒/预览数据。 |
| **私有 API** | 可选的 IMCore 助手(编辑/撤回/删除)受能力检测限制。 |

简单说,micaGO 通过你掌控的连接,把你的 iMessage 桥接到你的设备。消息历史以你的 Mac
上的「信息」数据为准。

---

## 🚀 快速开始

最简单的方式是运行 **Companion**,它会为你构建并启动内置的服务器:

1. 在 Xcode 中打开 `MicaGoServer/micago-mac-companion/MicaGoCompanion.xcodeproj` 并运行
   (或构建 release 版本再启动)。
2. 在提示时授予 **完全磁盘访问权限**,然后 **启动** 服务器。它默认绑定 `0.0.0.0:3000`
   (局域网可达)。
3. 在 Companion 的 **创建连接** 卡片上,显示二维码(或复制连接 JSON)。
4. 在安卓应用中,**扫描二维码** 或 **粘贴连接 JSON** 进行配对 —— 它会自动通过局域网连接。

更喜欢命令行?参见 [分组件构建](#-分组件构建)。

---

## 🛠 分组件构建

**服务器**(`MicaGoServer/micago-server`)

```sh
cd MicaGoServer/micago-server
go build ./cmd/micago        # 生成 ./micago
./micago --version
go test ./...
go run ./cmd/micago          # 首次运行会生成 ~/.micago/config.yaml 和一个令牌
```

**Companion**(`MicaGoServer/micago-mac-companion`)

```sh
cd MicaGoServer/micago-mac-companion
xcodebuild -project MicaGoCompanion.xcodeproj -scheme MicaGoCompanion -configuration Debug build
```

> Xcode 构建阶段会把内置的 `micago` 后端 **以及** `micago-imcore-helper` 编译进应用的
> `Resources/`。

**客户端**(`MicaGoFlutterClient`)

```sh
cd MicaGoFlutterClient
flutter pub get
flutter analyze
flutter test
flutter build apk --debug      # 或：flutter run
```

---

## 🧰 可选功能

这些功能均为可选,并且 **默认关闭**。

- **保活服务(安卓)。** 最简单、多数人会用的方式:一个前台服务把连接保持打开,来消息时
  弹出本地通知。默认关闭;厂商电池策略
  仍可能限制它。
- **Firebase / FCM 推送。** 不想一直挂着服务?那就接上你 **自己的** Firebase 项目走后台
  推送。FCM 只发 data-only 消息;客户端用同一套本地 MessagingStyle 通知显示,
  再通过 WebSocket 或增量同步拉取消息。参见
  [`docs/setup/firebase/`](docs/setup/firebase/README.md)。
- **编辑 / 撤回 / 删除(IMCore 助手)。** 一个小巧的内置助手,调用 macOS 私有 IMCore API。
  - *用途* —— 从手机端编辑/撤回/删除一条已发的 iMessage。
  - *能力行为* —— 如果你的 Mac 无法授予 IMCore 访问,应用会报告 *能力不可用*,并隐藏这些操作。
- **远程访问。** 在服务器前自行架设反向代理 / 隧道(例如 Cloudflare Tunnel),并在
  Companion 中设置 **公网地址**。参见
  [`docs/remote-access-cloudflare.md`](docs/remote-access-cloudflare.md)。

---

## 🗂 仓库结构

```
MicaGo/
├── MicaGoServer/
│   ├── micago-server/          # Go 中继服务器（`micago` 可执行文件）
│   ├── micago-mac-companion/   # macOS SwiftUI 菜单栏 Companion
│   └── docs/                   # 软件/设计文档 + CHANGELOG
├── MicaGoFlutterClient/        # Flutter 安卓客户端
├── docs/                       # 用户指南（快速上手、远程访问……）
└── README.md
```

> `Ref/`（若本地存在）存放开发期间使用的第三方参考项目,并已被 git 忽略。

## ⚠️ 局限性

- **绑定 macOS。** 服务器必须运行在已登录 iMessage 且已授予完全磁盘访问权限的 Mac 上。它
  读取实时的「信息」数据库。
- **编辑/撤回/删除** 取决于你的 Mac 是否授予私有 API(IMCore)访问;不可用之处会隐藏这些操作。
- **应用被杀后的通知** 靠保活服务;你愿意用 Firebase 的话,也可以靠你自己的
  `google-services.json`。重新打开后,socket 加增量同步会补齐消息。
- **只在安卓上验证过。** Flutter 客户端理论上也能构建到其他平台,只是目前只测试过安卓。API
  在设计上与客户端无关。
- micaGO 是独立项目。使用风险自负。

---

## 🤝 参与贡献

欢迎提交 issue 与 pull request。提交 PR 前:

- **服务器:** `go build ./... && go vet ./... && go test ./...`
- **客户端:** `flutter analyze && flutter test`
- **Companion:** 在 Xcode 中构建 `MicaGoCompanion` scheme。

尽量保持改动轻量、少依赖;切勿记录或提交 bearer 令牌或推送令牌。

---

## 🙏 致谢

micaGO 从两个开源项目身上学到很多 —— 它们各自啃下了 iMessage 里同样难处理的部分。我们感谢
它们的工作。

- **[BlueBubbles](https://github.com/BlueBubblesApp)** —— 一个成熟的 iMessage 桥接工具。
  贴纸、链接预览、位置、手写以及 Digital Touch 的处理,是我们分类、渲染这些消息类型时的参考。
- **[imsg](https://imsg.sh)**(作者 Peter Steinberger)—— 一个终端 iMessage 工具,它对
  `chat.db` 以及附件 / StickerCache 目录结构的清晰读取,指引了我们服务器的读取路径。

两者都是独立项目。

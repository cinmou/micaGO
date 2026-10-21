<p align="center">
  <img src="docs/assets/Server.png" alt="micaGOServer" width="120" />
</p>

<div align="center">

# micaGO

[English](README.md) · **简体中文** · [繁體中文](README.zh-Hant.md)

*一个自托管的 iMessage 桥接工具。*

[![文档](https://img.shields.io/badge/%E6%96%87%E6%A1%A3-0064E0?style=for-the-badge)](https://github.com/cinmou/micaGo/blob/main/docs/index.zh-Hans.md)
[![官网](https://img.shields.io/badge/%E5%AE%98%E7%BD%91-007AFF?style=for-the-badge)](https://micago.cinmou.uk)
[![快速上手](https://img.shields.io/badge/%E5%BF%AB%E9%80%9F%E4%B8%8A%E6%89%8B-0A1317?style=for-the-badge)](https://github.com/cinmou/micaGo/blob/main/docs/getting-started.zh-Hans.md)
[![安全模型](https://img.shields.io/badge/%E5%AE%89%E5%85%A8%E6%A8%A1%E5%9E%8B-31A24C?style=for-the-badge)](#安全)
[![远程访问](https://img.shields.io/badge/%E8%BF%9C%E7%A8%8B%E8%AE%BF%E9%97%AE-5D6C7B?style=for-the-badge)](https://github.com/cinmou/micaGo/blob/main/docs/remote-access-cloudflare.md)
[![Releases](https://img.shields.io/badge/Releases-B89B5E?style=for-the-badge)](https://github.com/cinmou/micaGO/releases)

</div>

---

## 概览

micaGO 把 Android、Linux 和 Windows 客户端连接到 Mac Messages。Go 后端读取消息，原生 Mac Companion 管理配对与设置，Windows 使用独立 WinUI 应用。

## 应用截图

### 安卓客户端

|  |  |  |
|:---:|:---:|:---:|
| <img src="docs/assets/Android%201.png" alt="安卓会话列表" width="240" /> | <img src="docs/assets/Android%202.png" alt="安卓设置界面" width="240" /> | <img src="docs/assets/Android%203.png" alt="安卓聊天界面" width="240" /> |

### 平板客户端

<p align="center">
  <a href="docs/assets/Pad%201.png"><img src="docs/assets/Pad%201.png" alt="平板分栏界面" width="260" /></a>
  <a href="docs/assets/Pad%202.png"><img src="docs/assets/Pad%202.png" alt="平板聊天界面" width="260" /></a>
  <a href="docs/assets/Pad%203.png"><img src="docs/assets/Pad%203.png" alt="平板设置界面" width="260" /></a>
</p>

### Windows

<p align="center">
  <a href="docs/assets/windows-chat.png"><img src="docs/assets/windows-chat.png" alt="Windows 客户端聊天界面" width="260" /></a>
  <a href="docs/assets/windows-chat-dark.png"><img src="docs/assets/windows-chat-dark.png" alt="Windows 客户端深色聊天界面" width="260" /></a>
  <a href="docs/assets/windows-appearance.png"><img src="docs/assets/windows-appearance.png" alt="Windows 客户端外观设置" width="260" /></a>
</p>

### Mac 伴侣应用

<p align="center">
  <a href="docs/assets/Companion1.png"><img src="docs/assets/Companion1.png" alt="Mac 伴侣应用仪表盘" width="260" /></a>
  <a href="docs/assets/Companion2.png"><img src="docs/assets/Companion2.png" alt="Mac 伴侣应用配对界面" width="260" /></a>
  <a href="docs/assets/Companion3.png"><img src="docs/assets/Companion3.png" alt="Mac 伴侣应用设置界面" width="260" /></a>
</p>

---

## 系统要求

Mac Companion 需要 macOS 13 或更新版本，以及 Messages 数据的完全磁盘访问权限。发送时 Messages 需运行，并获得相应 Automation 权限。Android 最低 Android 7.0 / API 24。Linux 使用 Flutter 客户端；Windows 使用原生客户端，界面主要在 Windows 11 环境验收。

首次配对建议同一 Wi-Fi。公网 HTTPS 为可选功能，使用自己的代理或隧道。仓库里有某个平台工程不代表它具有相同支持程度。

## 当前功能

收发文本、附件和语音，浏览历史、回复、回应、贴纸和媒体。客户端使用本地缓存，重连后补齐变化。隐藏聊天、隐藏消息与已读状态分别同步，规则见文档。

Android FCM 推送使用自己的 Firebase 项目。保活和 IMCore 消息操作同样可选，默认关闭，并受系统权限与能力检测限制。

## 安全

有效期 5 分钟的一次性邀请给每台设备发放独立凭据。丢失设备可在 Companion 撤销。LAN HTTPS/WSS 校验配对证书指纹，公网 HTTPS 校验系统信任链。默认 HTTP 3000 只用于本机控制/代理，设备走 TLS 3001。

FCM 预览可能包含名字和正文，公网代理可能终止 TLS；这不是应用层端到端加密。详见[连接](docs/features/connection.md)和[通知隐私](docs/features/notifications.md)。

## 安装与开发

下载 Mac 与对应客户端，把 Companion 放进应用程序，授权并启动后端，再生成邀请供客户端扫码或粘贴 JSON。[快速上手](docs/getting-started.zh-Hans.md)有完整步骤。

开发从[架构](docs/ARCHITECTURE.md)、[构建测试发布](docs/DEVELOPMENT.md)进入，再按任务阅读功能和平台说明，不必先读全部文档。

## 致谢

[BlueBubbles](https://github.com/BlueBubblesApp) 与 [imsg](https://imsg.sh) 为 Messages 行为研究提供参考，它们是独立项目。第三方图形与库保留各自[声明](MicaGoWindowsClient/THIRD-PARTY-NOTICES.md)和[符号来源](MicaGoFlutterClient/tool/compat_symbols/NOTICE.md)。

made with ♥️ for everyone

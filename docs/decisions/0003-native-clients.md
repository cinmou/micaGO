# 0003：共用协议，各端保留原生能力

状态：现行。整理日期：2026-10-21。

## 背景与选择

服务端提供 micaGO 自己的 REST / WebSocket 协议。Flutter 用于 Android / Linux，Windows 使用独立 WinUI 客户端，Mac Companion 使用 SwiftUI。

消息身份、发送确认和跨设备状态需要保持一致。通知模板、凭据存储、文件选择和窗口由各平台的现有能力处理。

## 代价

需要跨端契约测试和原生验收。同一功能的入口与视觉效果可能不同；某端构建成功不能证明其他端可用。

参考 BlueBubbles 的行为或 Unigram 的视觉不等于兼容它们的 API，也不授权复制其代码与资源。第三方资源遵循对应许可证。

## 边界

当前没有网页客户端或 Telegram 入口。目录中的平台工程、历史设想和实验代码都不能当作已经发布的能力。

这份记录整理现有组件边界，不推测当初选择 WinUI 而非其他 UI 框架的完整过程。

证据：[架构](../ARCHITECTURE.md)、[Flutter](../platforms/flutter.md)、[Windows](../platforms/windows.md)。

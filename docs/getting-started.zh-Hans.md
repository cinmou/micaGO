# 快速上手

[English](getting-started.md) · **简体中文** · [繁體中文](getting-started.zh-Hant.md)

micaGO 把其他设备连接到自己的 Mac Messages。Android 和 Linux 使用 Flutter 客户端，Windows 使用独立原生客户端。

## 安装 Mac 应用

1. 从 [Releases](https://github.com/cinmou/micaGO/releases) 下载 Mac Companion 和设备对应的客户端。
2. 把 Companion 移到“应用程序”后打开。Mac 需要 macOS 13 或更新版本。
3. 在系统设置授予完全磁盘访问权限，让后端读取 Messages。改完权限后必要时重启后端。
4. 在 Mac Messages 登录账号。发送时 Messages 需要运行，系统请求 Automation 权限时按实际需要授权。

在 Companion 启动服务器并确认可达。默认 `http://127.0.0.1:3000` 只用于本机控制；设备连接 HTTPS 端口 3001。

## 连接第一台设备

1. 第一次连接先让设备和 Mac 使用同一 Wi-Fi。
2. 在 Companion 的“创建连接”卡片生成配对码。
3. 在客户端扫描二维码或粘贴连接 JSON。Windows 和 Linux 可以不使用摄像头，直接粘贴 JSON。
4. 完成连接。如果码已过期或使用过，在 Mac 重新生成。

配对邀请有效期 5 分钟，只能用一次。设备会保存独立凭据，正常重连不需要再扫码。不要把配对 JSON 发到公开 issue。

检查聊天列表和实时连接，再用一个已有会话测试发送。显示等待确认时不要连续重发。

## 按需开启

- [外网访问](remote-access-cloudflare.md)：使用自己的公网 HTTPS 地址。
- [Firebase 推送](setup/firebase/README.md)：Android 可选功能。保活也是可选路径，首次配对不依赖它们。
- [手动检查](manual-test-flow.md)：附件、跨设备已读和后台通知。

丢失设备时在 Companion 撤销配对。清缓存不能直接删除整个 relay 数据库。[文档入口](index.md)提供当前功能规则与开发说明。

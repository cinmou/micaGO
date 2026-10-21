# micaGO 文件

[English / 工程入口](index.md) · [简体中文](index.zh-Hans.md) · **繁體中文**

安裝從[快速上手](getting-started.zh-Hant.md)開始。Android 與 Linux 使用 Flutter 用戶端，Windows 使用獨立原生用戶端；它們都連接自己的 Mac。

- [用戶端連線](android-client-connection.md)：掃碼、貼上 JSON、線路與常見連線錯誤。
- [外網連線](remote-access-cloudflare.md)：選用的 Cloudflare Tunnel。
- [Firebase 推播](setup/firebase/README.md)：自己的專案、設定檔與通知預覽。
- [推播疑難排解](setup/firebase/troubleshooting.md)。
- [手動檢查](manual-test-flow.md)：實際收發、多端已讀與背景通知。

開發與文件審查從[完整入口](index.md#development)進入。建議依[架構](ARCHITECTURE.md)、[連線](features/connection.md)、[訊息](features/messaging.md)、[未讀](features/unread.md)、[媒體](features/media.md)、[通知](features/notifications.md)閱讀。

配對碼有效期 5 分鐘，只能使用一次。裝置兌換獨立憑據後，正常重新連線不必再掃碼。遺失裝置時在 Mac 撤銷配對，不要把 QR 或憑據放進公開日誌。

# 快速上手

[English](getting-started.md) · [简体中文](getting-started.zh-Hans.md) · **繁體中文**

micaGO 把其他裝置連接到自己的 Mac Messages。Android 與 Linux 使用 Flutter 用戶端，Windows 使用獨立原生用戶端。

## 安裝 Mac 程式

1. 從 [Releases](https://github.com/cinmou/micaGO/releases) 下載 Mac Companion 與裝置對應的用戶端。
2. 把 Companion 移到「應用程式」後開啟。Mac 需要 macOS 13 或更新版本。
3. 在系統設定授予完整磁碟存取權，讓後端讀取 Messages。改完權限後必要時重新啟動後端。
4. 在 Mac Messages 登入帳號。傳送時 Messages 需要執行，系統要求 Automation 權限時依實際需求授權。

在 Companion 啟動伺服器並確認可連線。預設 `http://127.0.0.1:3000` 只用於本機控制；裝置連接 HTTPS 連接埠 3001。

## 連接第一台裝置

1. 第一次連線先讓裝置與 Mac 使用同一 Wi-Fi。
2. 在 Companion 的「建立連線」卡片產生配對碼。
3. 在用戶端掃描 QR 或貼上連線 JSON。Windows 與 Linux 可直接貼上 JSON，不必使用攝影機。
4. 完成連線。若配對碼已過期或使用過，在 Mac 重新產生。

配對邀請有效期 5 分鐘，只能用一次。裝置會儲存獨立憑據，正常重新連線不必再掃碼。不要把配對 JSON 放進公開 issue。

確認聊天列表與即時連線，再用已有會話測試傳送。顯示等待確認時不要連續重送。

## 按需開啟

- [外網存取](remote-access-cloudflare.md)：使用自己的公開 HTTPS 位址。
- [Firebase 推播](setup/firebase/README.md)：Android 選用功能。保活也是選用路徑，初次配對不依賴它們。
- [手動檢查](manual-test-flow.md)：附件、跨裝置已讀與背景通知。

遺失裝置時在 Companion 撤銷配對。清快取不能直接刪除整個 relay 資料庫。[文件入口](index.md)提供目前的功能規則與開發說明。

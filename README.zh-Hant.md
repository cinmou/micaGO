<p align="center"><img src="docs/assets/Server.png" alt="micaGO" width="120" /></p>

# micaGO

[English](README.md) · [简体中文](README.zh-Hans.md) · [繁體中文](README.zh-Hant.md)

**你的 iMessage、你的 Mac、你的裝置。**

micaGO 把 Android、Linux 與 Windows 用戶端連接到 Mac Messages。Go 後端讀取訊息，原生 Mac Companion 管理配對與設定，Windows 使用獨立 WinUI 程式。

[下載](https://github.com/cinmou/micaGO/releases) · [快速上手](docs/getting-started.zh-Hant.md) · [文件](docs/index.zh-Hant.md) · [官網](https://micago.cinmou.uk)

## 應用程式截圖

### Android 用戶端

|  |  |  |
|:---:|:---:|:---:|
| <img src="docs/assets/Android%201.png" alt="Android 對話列表" width="240" /> | <img src="docs/assets/Android%202.png" alt="Android 設定畫面" width="240" /> | <img src="docs/assets/Android%203.png" alt="Android 對話畫面" width="240" /> |

### 平板用戶端

<p align="center">
  <a href="docs/assets/Pad%201.png"><img src="docs/assets/Pad%201.png" alt="平板分割畫面" width="260" /></a>
  <a href="docs/assets/Pad%202.png"><img src="docs/assets/Pad%202.png" alt="平板對話畫面" width="260" /></a>
  <a href="docs/assets/Pad%203.png"><img src="docs/assets/Pad%203.png" alt="平板設定畫面" width="260" /></a>
</p>

### Windows

<p align="center">
  <a href="docs/assets/windows-chat.png"><img src="docs/assets/windows-chat.png" alt="Windows 用戶端聊天介面" width="260" /></a>
  <a href="docs/assets/windows-chat-dark.png"><img src="docs/assets/windows-chat-dark.png" alt="Windows 用戶端深色聊天介面" width="260" /></a>
  <a href="docs/assets/windows-appearance.png"><img src="docs/assets/windows-appearance.png" alt="Windows 用戶端外觀設定" width="260" /></a>
</p>

### Mac 伴隨程式

<p align="center">
  <a href="docs/assets/Companion1.png"><img src="docs/assets/Companion1.png" alt="Mac 伴隨程式儀表板" width="260" /></a>
  <a href="docs/assets/Companion2.png"><img src="docs/assets/Companion2.png" alt="Mac 伴隨程式配對畫面" width="260" /></a>
  <a href="docs/assets/Companion3.png"><img src="docs/assets/Companion3.png" alt="Mac 伴隨程式設定畫面" width="260" /></a>
</p>

---

## 系統需求

Mac Companion 需要 macOS 13 或更新版本，以及 Messages 資料的完整磁碟存取權。傳送時 Messages 需執行，並取得相應 Automation 權限。Android 最低 Android 7.0 / API 24。Linux 使用 Flutter 用戶端；Windows 使用原生用戶端，介面主要在 Windows 11 環境驗收。

初次配對建議使用同一 Wi-Fi。公開 HTTPS 為選用功能，使用自己的代理或通道。儲存庫內有某個平台工程不代表它具有相同支援程度。

## 目前功能

收發文字、附件與語音，瀏覽歷史、回覆、回應、貼圖與媒體。用戶端使用本機快取，重新連線後補齊變更。隱藏聊天、隱藏訊息與已讀狀態分別同步，規則見文件。

Android FCM 推播使用自己的 Firebase 專案。保活與 IMCore 訊息操作同樣為選用功能，預設關閉，並受系統權限與能力檢測限制。

## 安全

有效期 5 分鐘的一次性邀請給每台裝置發放獨立憑據。遺失裝置可在 Companion 撤銷。LAN HTTPS/WSS 校驗配對憑證指紋，公開 HTTPS 校驗系統信任鏈。預設 HTTP 3000 只用於本機控制/代理，裝置使用 TLS 3001。

FCM 預覽可能包含名字與內容，公開代理可能終止 TLS；這不是應用層端對端加密。詳見[連線](docs/features/connection.md)與[推播隱私](docs/features/notifications.md)。

## 安裝與開發

下載 Mac 與對應用戶端，把 Companion 放進應用程式，授權並啟動後端，再產生邀請供用戶端掃碼或貼上 JSON。[快速上手](docs/getting-started.zh-Hant.md)有完整步驟。

開發從[架構](docs/ARCHITECTURE.md)、[建置測試發布](docs/DEVELOPMENT.md)進入，再依任務閱讀功能與平台說明，不必先讀全部文件。

## 致謝

[BlueBubbles](https://github.com/BlueBubblesApp) 與 [imsg](https://imsg.sh) 為 Messages 行為研究提供參考，它們是獨立專案。第三方圖形與函式庫保留各自[聲明](MicaGoWindowsClient/THIRD-PARTY-NOTICES.md)與[符號來源](MicaGoFlutterClient/tool/compat_symbols/NOTICE.md)。

made with ♥️ for everyone

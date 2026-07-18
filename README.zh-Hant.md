<p align="center">
  <img src="docs/assets/Server.png" alt="micaGOServer" width="120" />
</p>

<div align="center">

# micaGO

[English](README.md) · [简体中文](README.zh-Hans.md) · **繁體中文**

**你的 iMessage、你的 Mac、你的裝置。**
*一個自架的 iMessage 橋接工具。*

*Built with ♥️ for everyone.*

[![文件](https://img.shields.io/badge/%E6%96%87%E4%BB%B6-0064E0?style=for-the-badge)](https://github.com/cinmou/micaGo/blob/main/docs/index.zh-Hant.md)
[![官網](https://img.shields.io/badge/%E5%AE%98%E7%B6%B2-007AFF?style=for-the-badge)](https://micago.cinmou.uk)
[![快速上手](https://img.shields.io/badge/%E5%BF%AB%E9%80%9F%E4%B8%8A%E6%89%8B-0A1317?style=for-the-badge)](https://github.com/cinmou/micaGo/blob/main/docs/getting-started.zh-Hant.md)
[![安全模型](https://img.shields.io/badge/%E5%AE%89%E5%85%A8%E6%A8%A1%E5%9E%8B-31A24C?style=for-the-badge)](https://github.com/cinmou/micaGo#-%E5%AE%89%E5%85%A8%E6%A8%A1%E5%9E%8B)
[![遠端存取](https://img.shields.io/badge/%E9%81%A0%E7%AB%AF%E5%AD%98%E5%8F%96-5D6C7B?style=for-the-badge)](https://github.com/cinmou/micaGo/blob/main/docs/remote-access-cloudflare.md)
[![CHANGELOG](https://img.shields.io/badge/CHANGELOG-B89B5E?style=for-the-badge)](https://github.com/cinmou/micaGo/blob/main/MicaGoServer/docs/CHANGELOG.md)

</div>

---

## 概覽

micaGO 讓你 **自己的** Android 手機,透過你 **自己的** Mac,收發你的 iMessage。Mac 上的
一個小巧 Go 伺服器讀取本機「訊息」資料庫,提供一套私密、受權杖保護的 API;一個 macOS
選單列 **Companion(伴隨程式)** 負責執行並管理它;一個 **Flutter Android 應用程式** 透過
你的 Wi‑Fi(或你自行掌控的選用公開網址)與之配對。你的資料始終只在 **你的** Mac 和
**你的** 裝置之間傳輸。

micaGO 仍處在測試階段。它會讀取 macOS「訊息」的內部資料,並需要「完全取用磁碟」權限。
在依賴它之前,請先閱讀 [安全模型](#-安全模型) 與 [限制](#-限制)。micaGO 是獨立專案。

## 應用程式截圖

| Android 用戶端 | Android 用戶端 | Android 用戶端 |
|:---:|:---:|:---:|
| <img src="docs/assets/Android%201.png" alt="Android 對話列表" width="240" /> | <img src="docs/assets/Android%202.png" alt="Android 設定畫面" width="240" /> | <img src="docs/assets/Android%203.png" alt="Android 對話畫面" width="240" /> |

| 平板用戶端 | 平板用戶端 | 平板用戶端 |
|:---:|:---:|:---:|
| <img src="docs/assets/Pad%201.png" alt="平板分割畫面" width="360" /> | <img src="docs/assets/Pad%202.png" alt="平板對話畫面" width="360" /> | <img src="docs/assets/Pad%203.png" alt="平板設定畫面" width="360" /> |

| Mac 伴隨程式 | Mac 伴隨程式 | Mac 伴隨程式 |
|:---:|:---:|:---:|
| <img src="docs/assets/Companion1.png" alt="Mac 伴隨程式儀表板" width="360" /> | <img src="docs/assets/Companion2.png" alt="Mac 伴隨程式配對畫面" width="360" /> | <img src="docs/assets/Companion3.png" alt="Mac 伴隨程式設定畫面" width="360" /> |

---

## ✅ 系統需求

- **Mac Companion:** macOS 13 或更新版本,需要已登入 iMessage,並授予「完全取用磁碟」
  權限以讀取「訊息」資料。
- **Android 用戶端:** Android 6.0 或更新版本(API 23+)。用戶端包含手機、平板和大螢幕版面。
- **網路:** 首次設定建議使用區域網路。遠端存取是選用功能,需要你自己的公開網址或通道。

---

## ✨ 你能得到什麼

- **自架。** 橋接服務執行在你的 Mac 上。選用的推播與遠端存取使用 **你** 自己擁有並
  設定的服務。
- **對話與訊息。** 對話列表、訊息串、點按回應(Tapback)、引用回覆、傳送特效、貼圖、
  **位置 / 手寫 / Digital Touch**,以及內嵌圖片/影片與全螢幕檢視器。
- **傳送。** 透過 iMessage 傳送文字與附件、**語音訊息**,以及在你開啟後傳送簡訊
  (預設關閉,由伺服器設定控制)。
- **即時 + 補齊。** WebSocket 事件用於即時更新,再加上以游標為基礎的 **增量(delta)**
  同步,在程式關閉後補上遺漏。
- **區域網路優先。** 會公告多條區域網路路由;用戶端自動選擇可達的一條並允許你釘選。
  選用的公開網址(你自己的通道)可在任何地方存取。
- **聯絡人比對。** 在本機做姓名比對,需選擇啟用,並保留在本裝置上。
- **通知(選用)。** 保活和 FCM 都走用戶端本機的 Android MessagingStyle 通知樣式。想用
  推播,接上你 **自己的** Firebase 即可。

---

## 🧩 運作原理

```
            ┌──────────────────────── 你的 Mac ────────────────────────┐
            │                                                            │
 訊息       │   chat.db ──► 同步迴圈 ──► relay.db ──► REST + WebSocket   │
 (iMessage) │      ▲                                        │           │
            │      │ AppleScript / 選用的 IMCore 輔助程式    │           │
            │   ┌──┴───────────────┐                         │           │
            │   │  Mac Companion   │  執行並管理伺服器                   │
            │   │  （選單列程式）  │                         │           │
            │   └──────────────────┘                         │           │
            └────────────────────────────────────────────────┼──────────┘
                                                              │
                       區域網路（同一 Wi‑Fi）  ──或──  選用公開網址（你的通道）
                                                              │
                                                   ┌──────────▼──────────┐
                                                   │     Android 用戶端  │
                                                   │   （Flutter 程式）  │
                                                   └─────────────────────┘
```

- **讀取路徑** —— 伺服器將 `chat.db` 單向同步進自己的 `relay.db`,再提供一套小而穩定的
  REST + WebSocket API。用戶端透過以游標為基礎的 **增量** 補齊,並透過 socket 取得即時事件。
- **傳送路徑** —— 文字透過 AppleScript 經由「訊息」傳送;附件透過 multipart 上傳。編輯 /
  收回 / 刪除 使用選用的內建 [IMCore 輔助程式](#-選用功能)。
- **配對** —— Companion 顯示包含區域網路/公開候選位址與一個 bearer 權杖的 QR code / 連線
  JSON;用戶端掃描或貼上它。

---

## 🔐 安全模型

micaGO 是 **本機優先** 的,設計上讓你的資料始終屬於你。

| 關注點 | micaGO 如何處理 |
| --- | --- |
| **驗證** | 每個 API 呼叫都需要伺服器產生的 **bearer 權杖**(`~/.micago/config.yaml`)。任何同時擁有你的網址 **和** 權杖的人都能存取你的 Mac —— 請像密碼一樣對待它。 |
| **網路** | 預設繫結到你的 **區域網路**。公開暴露需你主動開啟,且由你負責;任何離開你網路的流量都應優先用 HTTPS。 |
| **你的資料** | 訊息從你的 Mac 提供給已配對裝置。聯絡人在本機比對。 |
| **推播** | 若你啟用 FCM,負載攜帶用於通知遞送的小型喚醒/預覽資料。 |
| **私有 API** | 選用的 IMCore 輔助程式(編輯/收回/刪除)受能力偵測限制。 |

簡單說,micaGO 透過你掌控的連線,把你的 iMessage 橋接到你的裝置。訊息歷史以你的 Mac
上的「訊息」資料為準。

---

## 🚀 快速開始

最簡單的方式是執行 **Companion**,它會為你建置並啟動內建的伺服器:

1. 在 Xcode 中開啟 `MicaGoServer/micago-mac-companion/MicaGoCompanion.xcodeproj` 並執行
   (或建置 release 版本再啟動)。
2. 在提示時授予 **完全取用磁碟** 權限,然後 **啟動** 伺服器。它預設繫結 `0.0.0.0:3000`
   (區域網路可達)。
3. 在 Companion 的 **建立連線** 卡片上,顯示 QR code(或複製連線 JSON)。
4. 在 Android 程式中,**掃描 QR code** 或 **貼上連線 JSON** 進行配對 —— 它會自動透過區域
   網路連線。

偏好命令列?參見 [分元件建置](#-分元件建置)。

---

## 🛠 分元件建置

**伺服器**(`MicaGoServer/micago-server`)

```sh
cd MicaGoServer/micago-server
go build ./cmd/micago        # 產生 ./micago
./micago --version
go test ./...
go run ./cmd/micago          # 首次執行會產生 ~/.micago/config.yaml 和一個權杖
```

**Companion**(`MicaGoServer/micago-mac-companion`)

```sh
cd MicaGoServer/micago-mac-companion
xcodebuild -project MicaGoCompanion.xcodeproj -scheme MicaGoCompanion -configuration Debug build
```

> Xcode 建置階段會把內建的 `micago` 後端 **以及** `micago-imcore-helper` 編譯進程式的
> `Resources/`。

**用戶端**(`MicaGoFlutterClient`)

```sh
cd MicaGoFlutterClient
flutter pub get
flutter analyze
flutter test
flutter build apk --debug      # 或：flutter run
```

---

## 🧰 選用功能

這些功能均為選用,並且 **預設關閉**。

- **保活服務(Android)。** 最簡單、多數人會用的方式:一個前景服務把連線保持開啟,來訊息時
  彈出本機通知。預設關閉;廠商電池策略
  仍可能限制它。
- **Firebase / FCM 推播。** 不想一直掛著服務?那就接上你 **自己的** Firebase 專案走背景
  推播。FCM 只發 data-only 訊息;用戶端用同一套本機 MessagingStyle 通知顯示,
  再透過 WebSocket 或增量同步拉取訊息。參見
  [`docs/setup/firebase/`](docs/setup/firebase/README.md)。
- **編輯 / 收回 / 刪除(IMCore 輔助程式)。** 一個小巧的內建輔助程式,呼叫 macOS 私有 IMCore API。
  - *用途* —— 從手機端編輯/收回/刪除一則已傳的 iMessage。
  - *能力行為* —— 如果你的 Mac 無法授予 IMCore 存取,應用程式會回報 *能力不可用*,並隱藏這些操作。
- **遠端存取。** 在伺服器前自行架設反向代理 / 通道(例如 Cloudflare Tunnel),並在
  Companion 中設定 **公開網址**。參見
  [`docs/remote-access-cloudflare.md`](docs/remote-access-cloudflare.md)。

---

## 🗂 儲存庫結構

```
MicaGo/
├── MicaGoServer/
│   ├── micago-server/          # Go 中繼伺服器（`micago` 執行檔）
│   ├── micago-mac-companion/   # macOS SwiftUI 選單列 Companion
│   └── docs/                   # 軟體/設計文件 + CHANGELOG
├── MicaGoFlutterClient/        # Flutter Android 用戶端
├── docs/                       # 使用者指南（快速上手、遠端存取……）
└── README.md
```

> `Ref/`（若本機存在）存放開發期間使用的第三方參考專案,並已被 git 忽略。

## ⚠️ 限制

- **繫結 macOS。** 伺服器必須執行在已登入 iMessage 且已授予完全取用磁碟權限的 Mac 上。它
  讀取即時的「訊息」資料庫。
- **編輯/收回/刪除** 取決於你的 Mac 是否授予私有 API(IMCore)存取;不可用之處會隱藏這些操作。
- **程式被終止後的通知** 靠保活服務;你願意用 Firebase 的話,也可以靠你自己的
  `google-services.json`。重新開啟後,socket 加增量同步會補齊訊息。
- **只在 Android 上驗證過。** Flutter 用戶端理論上也能建置到其他平台,只是目前只測試過
  Android。API 在設計上與用戶端無關。
- micaGO 是獨立專案。使用風險自負。

---

## 🤝 參與貢獻

歡迎提交 issue 與 pull request。提交 PR 前:

- **伺服器:** `go build ./... && go vet ./... && go test ./...`
- **用戶端:** `flutter analyze && flutter test`
- **Companion:** 在 Xcode 中建置 `MicaGoCompanion` scheme。

盡量保持改動輕量、少依賴;切勿記錄或提交 bearer 權杖或推播權杖。

---

## 🙏 致謝

micaGO 從兩個開源專案身上學到很多 —— 它們各自啃下了 iMessage 裡同樣難處理的部分。我們感謝
它們的工作。

- **[BlueBubbles](https://github.com/BlueBubblesApp)** —— 一個成熟的 iMessage 橋接工具。
  貼圖、連結預覽、位置、手寫以及 Digital Touch 的處理,是我們分類、算繪這些訊息類型時的參考。
- **[imsg](https://imsg.sh)**(作者 Peter Steinberger)—— 一個終端 iMessage 工具,它對
  `chat.db` 以及附件 / StickerCache 目錄結構的清晰讀取,指引了我們伺服器的讀取路徑。

兩者都是獨立專案。

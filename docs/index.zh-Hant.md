# micaGO —— 使用者文件

[English](index.md) · [简体中文](index.zh-Hans.md) · **繁體中文**

[← 專案 README](../README.zh-Hant.md) · [快速上手](getting-started.zh-Hant.md) · [CHANGELOG](../MicaGoServer/docs/CHANGELOG.md)

---

這些指南幫助你設定 Mac 程式、從手機連線,並（選用）從任何地方存取你的 Mac。
micaGO 讓你 **自己的** 裝置與 **你自己的** Mac 通訊,訊息在你的 Mac 和你連線的裝置之間流轉。

---

## 📚 指南

- **[快速上手](getting-started.zh-Hant.md)** —— 第一次設定:你需要準備什麼、在哪裡找到
  伺服器網址和權杖,以及測試每條連線的建議順序。
- **[Android 用戶端連線](android-client-connection.md)**（英文）—— 透過區域網路或公開
  網址配對 Android 程式,以及它支援哪些功能。
- **[使用 Cloudflare Tunnel 遠端存取](remote-access-cloudflare.md)**（英文）—— 借助
  你自己的網域從家用網路外存取你的 Mac。通道是 **外部且選用** 的,由你管理。
- **[推播通知](notifications-setup.md)**（英文）—— 選用的自架 Firebase / FCM 設定與
  Android 通知疑難排解。
- **[Firebase 設定參考](setup/firebase/README.md)**（英文）—— 同樣的選用推播設定,以
  聚焦清單 + 更深入的逐步頁面呈現。
- **[手動測試流程](manual-test-flow.md)**（英文）—— 一份可複製貼上的清單,從零開始確認
  本機、區域網路、公開與用戶端連通性。

> 部分指南目前仍為英文;`快速上手` 已有简/繁中文版本,其餘正在逐步在地化。

---

## 🔐 安全須知

- 你的 **bearer 權杖** 就是伺服器的密碼。任何同時擁有你的公開網址 **和** 權杖的人都能存取
  你的 Mac —— 請保密。
- 切勿把權杖貼進截圖、公開日誌、錯誤回報、聊天或 issue 追蹤器。
- 任何離開家用網路的連線都應優先使用 **HTTPS**（Cloudflare 指南會自動給你 HTTPS）。
- 若你認為權杖已外洩,請在 Mac 程式中產生新權杖並重新連線。

---

## 🧭 各部分在哪裡

- **Mac Companion** 執行伺服器,顯示你的區域網路 + 選用公開連線資訊、已配對裝置與診斷。
- **Android 程式** 透過區域網路（同一 Wi‑Fi）或選用公開網址配對,同步對話,傳送文字 +
  附件 + 語音（以及你開啟後的簡訊),呈現回應/回覆/特效/媒體/貼圖/位置,並可選接收推播。
- **遠端存取** 使用你自己的網域 + Cloudflare Tunnel,或你選擇並管理的其他通道。

> 軟體/設計文件與開發歷史位於 [`MicaGoServer/docs/`](../MicaGoServer/docs/README.md) ——
> 這裡的 `/docs` 指南是給 **使用** micaGO 的人看的。

詳情見各指南,建置說明與完整功能列表見 [專案 README](../README.zh-Hant.md)。

import Foundation

enum L10n {
    static let languageKey = "appLanguage"
    static let supportedLanguages = ["system", "en", "zh-Hans", "zh-Hant"]

    static var languageIdentifier: String {
        languageIdentifier(for: UserDefaults.standard.string(forKey: languageKey) ?? "system")
    }

    static func languageIdentifier(for choice: String, preferredLanguage: String = Locale.preferredLanguages.first ?? "en") -> String {
        let requested = supportedLanguages.contains(choice) && choice != "system"
            ? choice : preferredLanguage
        let language = requested.lowercased()
        if language.hasPrefix("zh-hant") || language.hasPrefix("zh-tw") || language.hasPrefix("zh-hk") || language.hasPrefix("zh-mo") {
            return "zh-Hant"
        }
        return language.hasPrefix("zh") ? "zh-Hans" : "en"
    }

    static var locale: Locale { Locale(identifier: languageIdentifier) }

    static func localized(_ key: String.LocalizationValue) -> String {
        // Select the catalog's language bundle explicitly. Locale also controls
        // formatting; it does not replace Bundle's preferred-language lookup.
        let bundle = Bundle.main.path(forResource: languageIdentifier, ofType: "lproj")
            .flatMap(Bundle.init(path:)) ?? Bundle.main
        return String(localized: key, bundle: bundle, locale: locale)
    }

    static func tr(_ key: String) -> String {
        let table = languageIdentifier == "zh-Hant" ? zhHant
            : languageIdentifier == "zh-Hans" ? zhHans : en
        return table[key] ?? en[key] ?? key
    }

    private static let en = [
        "language.title": "Language",
        "language.system": "System language",
        "language.help": "Changes apply immediately.",
        "pairing.remaining": "Pairing code expires in %@. It can be used once.",
        "pairing.awaitingDevice": "Awaiting device connection",
        "pairing.used": "Pairing code used. Create a new code to connect another device.",
        "pairing.expired": "Pairing code expired. Create a new code to continue.",
        "pairing.invalidated": "Pairing code replaced. Create a new code to continue.",
        "prefs.title": "Hidden Chats",
        "prefs.description": "Hidden chats keep syncing, but they leave the chat list and stop notifying on every device. Sync Control rules don't change.",
        "prefs.select": "Choose a chat",
        "prefs.hide": "Hide",
        "prefs.restore": "Restore",
        "prefs.blocked": "Sync blocked",
        "prefs.offline": "Not synced yet. Retry when connected.",
        "prefs.conflict": "Another device changed these preferences. Choose which changes to keep.",
        "prefs.server": "Keep server settings",
        "prefs.mine": "Apply my changes",
        "sidebar.dashboard": "Dashboard",
        "sidebar.connections": "Connections",
        "sidebar.syncControl": "Sync Control",
        "sidebar.notifications": "Notifications",
        "sidebar.tutorials": "Tutorials",
        "sidebar.about": "About",
        "sidebar.advanced": "Settings",
        "sidebar.debug": "Debug",
        "sidebar.log": "Log",
        "menu.running": "micaGO backend is running",
        "menu.external": "micaGO backend is running outside Companion",
        "menu.notRunning": "micaGO backend is not running",
        "menu.openDashboard": "Open Dashboard",
        "menu.startServer": "Start Server",
        "menu.stopServer": "Stop Server",
        "menu.keepAwake": "Keep Awake",
        "menu.aboutApp": "About micaGO",
        "menu.checkUpdates": "Check for Updates…",
        "menu.settings": "Settings…",
        "menu.quit": "Quit micaGO Companion",
        // Sync Control page
        "sync.title": "Sync Control",
        "sync.desc": "Choose which conversations the relay saves. Blocking a chat stops new messages from syncing, and messages already synced stay.",
        "sync.loadErrorTitle": "Couldn't load Sync Control",
        "sync.requestsFailed": "These requests failed:",
        "sync.loadErrorHelp": "The server answered, but a Sync Control request failed. If you just updated the backend, quit it completely and start it again, then retry. You can also copy diagnostics to share.",
        "sync.retry": "Retry",
        "sync.copyDiagnostics": "Copy diagnostics",
        "sync.contacts": "Contacts",
        "sync.requestContacts": "Request Contacts Access",
        "sync.openSystemSettings": "Open System Settings",
        "sync.findContact": "Find a Contact",
        "sync.defaultPolicy": "Default Policy",
        "sync.backfill": "Backfill & Services",
        "sync.chats": "Chats",
        "sync.activeRules": "Active Rules",
    ]

    private static let zhHans = [
        "language.title": "语言",
        "language.system": "跟随系统",
        "language.help": "更改立即生效。",
        "pairing.remaining": "配对码将在 %@ 后过期，仅可使用一次。",
        "pairing.awaitingDevice": "等待设备连接",
        "pairing.used": "配对码已使用。连接其他设备请生成新配对码。",
        "pairing.expired": "配对码已过期，请生成新配对码。",
        "pairing.invalidated": "配对码已被替换，请生成新配对码。",
        "prefs.title": "隐藏聊天",
        "prefs.description": "隐藏的聊天照常同步，但会从所有设备的聊天列表中消失，也不再通知。同步控制规则不变。",
        "prefs.select": "选择聊天",
        "prefs.hide": "隐藏",
        "prefs.restore": "恢复显示",
        "prefs.blocked": "已阻止同步",
        "prefs.offline": "尚未同步，连接后重试。",
        "prefs.conflict": "其他设备已修改隐藏状态，请选择要保留的设置。",
        "prefs.server": "保留服务器设置",
        "prefs.mine": "应用我的修改",
        "sidebar.dashboard": "仪表盘",
        "sidebar.connections": "连接",
        "sidebar.syncControl": "同步控制",
        "sidebar.notifications": "通知",
        "sidebar.tutorials": "教程",
        "sidebar.about": "关于",
        "sidebar.advanced": "设置",
        "sidebar.debug": "调试",
        "sidebar.log": "日志",
        "menu.running": "micaGO 后端正在运行",
        "menu.external": "micaGO 后端在 Companion 之外运行",
        "menu.notRunning": "micaGO 后端未运行",
        "menu.openDashboard": "打开仪表盘",
        "menu.startServer": "启动服务器",
        "menu.stopServer": "停止服务器",
        "menu.keepAwake": "保持唤醒",
        "menu.aboutApp": "关于 micaGO",
        "menu.checkUpdates": "检查更新…",
        "menu.settings": "设置…",
        "menu.quit": "退出 micaGO Companion",
        "sync.title": "同步控制",
        "sync.desc": "选择哪些会话保存到中继。屏蔽后不再同步新消息，已同步的消息会保留。",
        "sync.loadErrorTitle": "无法加载同步控制",
        "sync.requestsFailed": "以下请求失败：",
        "sync.loadErrorHelp": "服务器有响应，但同步控制请求失败了。如果刚更新过后端，请完全退出后重新启动，再点重试。也可以复制诊断信息发给别人。",
        "sync.retry": "重试",
        "sync.copyDiagnostics": "复制诊断信息",
        "sync.contacts": "联系人",
        "sync.requestContacts": "请求联系人权限",
        "sync.openSystemSettings": "打开系统设置",
        "sync.findContact": "查找联系人",
        "sync.defaultPolicy": "默认策略",
        "sync.backfill": "回填与服务",
        "sync.chats": "会话",
        "sync.activeRules": "生效的规则",
    ]

    private static let zhHant = [
        "language.title": "語言",
        "language.system": "跟隨系統",
        "language.help": "變更立即生效。",
        "pairing.remaining": "配對碼將在 %@ 後過期，僅可使用一次。",
        "pairing.awaitingDevice": "等待裝置連線",
        "pairing.used": "配對碼已使用。連線其他裝置請產生新配對碼。",
        "pairing.expired": "配對碼已過期，請產生新配對碼。",
        "pairing.invalidated": "配對碼已被替換，請產生新配對碼。",
        "prefs.title": "隱藏聊天",
        "prefs.description": "隱藏的聊天照常同步，但會從所有裝置的聊天列表中消失，也不再通知。同步控制規則不變。",
        "prefs.select": "選擇聊天",
        "prefs.hide": "隱藏",
        "prefs.restore": "恢復顯示",
        "prefs.blocked": "已阻止同步",
        "prefs.offline": "尚未同步，連線後重試。",
        "prefs.conflict": "其他裝置已修改隱藏狀態，請選擇要保留的設定。",
        "prefs.server": "保留伺服器設定",
        "prefs.mine": "套用我的修改",
        "sidebar.dashboard": "儀表板",
        "sidebar.connections": "連線",
        "sidebar.syncControl": "同步控制",
        "sidebar.notifications": "通知",
        "sidebar.tutorials": "教學",
        "sidebar.about": "關於",
        "sidebar.advanced": "設定",
        "sidebar.debug": "除錯",
        "sidebar.log": "日誌",
        "menu.running": "micaGO 後端正在執行",
        "menu.external": "micaGO 後端在 Companion 之外執行",
        "menu.notRunning": "micaGO 後端未執行",
        "menu.openDashboard": "開啟儀表板",
        "menu.startServer": "啟動伺服器",
        "menu.stopServer": "停止伺服器",
        "menu.keepAwake": "保持喚醒",
        "menu.aboutApp": "關於 micaGO",
        "menu.checkUpdates": "檢查更新…",
        "menu.settings": "設定…",
        "menu.quit": "結束 micaGO Companion",
        "sync.title": "同步控制",
        "sync.desc": "選擇哪些對話儲存到中繼。封鎖後不再同步新訊息，已同步的訊息會保留。",
        "sync.loadErrorTitle": "無法載入同步控制",
        "sync.requestsFailed": "以下請求失敗：",
        "sync.loadErrorHelp": "伺服器有回應，但同步控制請求失敗了。如果剛更新過後端，請完全結束後重新啟動，再點重試。也可以複製診斷資訊傳給別人。",
        "sync.retry": "重試",
        "sync.copyDiagnostics": "複製診斷資訊",
        "sync.contacts": "聯絡人",
        "sync.requestContacts": "請求聯絡人權限",
        "sync.openSystemSettings": "開啟系統設定",
        "sync.findContact": "尋找聯絡人",
        "sync.defaultPolicy": "預設原則",
        "sync.backfill": "回填與服務",
        "sync.chats": "對話",
        "sync.activeRules": "生效的規則",
    ]
}

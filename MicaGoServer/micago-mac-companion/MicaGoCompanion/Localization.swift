import Foundation

enum L10n {
    static func tr(_ key: String) -> String {
        let lang = Locale.preferredLanguages.first?.lowercased() ?? "en"
        let table: [String: String]
        if lang.hasPrefix("zh-hant") || lang.hasPrefix("zh-tw") || lang.hasPrefix("zh-hk") {
            table = zhHant
        } else if lang.hasPrefix("zh") {
            table = zhHans
        } else {
            table = en
        }
        return table[key] ?? en[key] ?? key
    }

    private static let en = [
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
        "menu.external": "micaGO backend is reachable but not managed by Companion",
        "menu.notRunning": "micaGO backend is not running",
        "menu.openDashboard": "Open Dashboard",
        "menu.startServer": "Start Server",
        "menu.stopServer": "Stop Server",
        "menu.keepAwake": "Keep Awake",
        "menu.quit": "Quit micaGO Companion",
        // Sync Control page
        "sync.title": "Sync Control",
        "sync.desc": "Choose which conversations are saved to the relay. This is a privacy/management view, not a chat client. Blocking a chat stops future sync; messages already synced are kept.",
        "sync.loadErrorTitle": "Couldn't load Sync Control",
        "sync.requestsFailed": "These requests failed:",
        "sync.loadErrorHelp": "The server is reachable but a Sync Control request failed. If the backend was just updated, fully quit and relaunch it (migrations run on start). Then retry, or copy diagnostics to share.",
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
        "menu.external": "micaGO 后端可访问，但不由 Companion 管理",
        "menu.notRunning": "micaGO 后端未运行",
        "menu.openDashboard": "打开仪表盘",
        "menu.startServer": "启动服务器",
        "menu.stopServer": "停止服务器",
        "menu.keepAwake": "保持唤醒",
        "menu.quit": "退出 micaGO Companion",
        "sync.title": "同步控制",
        "sync.desc": "选择哪些会话保存到中继。这是一个隐私/管理视图，而非聊天客户端。屏蔽某个会话会停止其今后的同步；已同步的消息会保留。",
        "sync.loadErrorTitle": "无法加载同步控制",
        "sync.requestsFailed": "以下请求失败：",
        "sync.loadErrorHelp": "服务器可达，但某个同步控制请求失败了。如果刚更新过后端，请彻底退出并重新启动它（迁移会在启动时运行），然后重试，或复制诊断信息以便分享。",
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
        "menu.external": "micaGO 後端可連線，但不由 Companion 管理",
        "menu.notRunning": "micaGO 後端未執行",
        "menu.openDashboard": "開啟儀表板",
        "menu.startServer": "啟動伺服器",
        "menu.stopServer": "停止伺服器",
        "menu.keepAwake": "保持喚醒",
        "menu.quit": "結束 micaGO Companion",
        "sync.title": "同步控制",
        "sync.desc": "選擇哪些對話儲存到中繼。這是一個隱私/管理檢視，而非聊天用戶端。封鎖某個對話會停止其今後的同步；已同步的訊息會保留。",
        "sync.loadErrorTitle": "無法載入同步控制",
        "sync.requestsFailed": "以下請求失敗：",
        "sync.loadErrorHelp": "伺服器可達，但某個同步控制請求失敗了。如果剛更新過後端，請徹底結束並重新啟動它（遷移會在啟動時執行），然後重試，或複製診斷資訊以便分享。",
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

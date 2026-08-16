using System.Globalization;

namespace MicaGo.App.Services;

public sealed class LocalizationService
{
    private static readonly IReadOnlyDictionary<string, IReadOnlyDictionary<string, string>> VcfStrings = new Dictionary<string, IReadOnlyDictionary<string, string>>
    {
        ["en"] = new Dictionary<string, string> { ["contactsHint"]="Match message handles with one or more vCard files. Embedded contact photos are imported locally.", ["importVcf"]="Import contacts from vCard (.vcf)", ["chooseVcf"]="Choose files…", ["clearContacts"]="Clear all", ["clearContactsTitle"]="Clear imported contacts?", ["clearContactsConfirm"]="All names and photos imported from vCard files will be removed from this PC.", ["contactsCleared"]="Imported contacts and photos cleared.", ["cancel"]="Cancel", ["importingVcf"]="Importing vCard contacts…", ["vcfImported"]="Imported {0} contacts across {1} addresses; skipped {2} cards.", ["vcfImportFailed"]="vCard import failed: {0}" },
        ["zh-Hans"] = new Dictionary<string, string> { ["contactsHint"]="使用一个或多个 vCard 文件匹配消息地址，内嵌联系人头像会保存在本机。", ["importVcf"]="从 vCard（.vcf）导入联系人", ["chooseVcf"]="选择文件…", ["clearContacts"]="全部清除", ["clearContactsTitle"]="清除已导入的联系人？", ["clearContactsConfirm"]="从 vCard 导入的所有姓名和头像都将从这台电脑移除。", ["contactsCleared"]="已清除导入的联系人和头像。", ["cancel"]="取消", ["importingVcf"]="正在导入 vCard 联系人…", ["vcfImported"]="已导入 {0} 位联系人、{1} 个地址；跳过 {2} 张名片。", ["vcfImportFailed"]="vCard 导入失败：{0}" },
        ["zh-Hant"] = new Dictionary<string, string> { ["contactsHint"]="使用一個或多個 vCard 檔案比對訊息地址，內嵌聯絡人頭像會儲存在本機。", ["importVcf"]="從 vCard（.vcf）匯入聯絡人", ["chooseVcf"]="選擇檔案…", ["clearContacts"]="全部清除", ["clearContactsTitle"]="清除已匯入的聯絡人？", ["clearContactsConfirm"]="從 vCard 匯入的所有姓名與頭像都會從這台電腦移除。", ["contactsCleared"]="已清除匯入的聯絡人與頭像。", ["cancel"]="取消", ["importingVcf"]="正在匯入 vCard 聯絡人…", ["vcfImported"]="已匯入 {0} 位聯絡人、{1} 個地址；略過 {2} 張名片。", ["vcfImportFailed"]="vCard 匯入失敗：{0}" },
    };
    private static readonly IReadOnlyDictionary<string, IReadOnlyDictionary<string, string>> Tables = new Dictionary<string, IReadOnlyDictionary<string, string>>
    {
        ["en"] = Common(new() { ["search"]="Search conversations", ["message"]="Message", ["settings"]="Settings", ["connection"]="Connection", ["appearance"]="Appearance", ["language"]="Language", ["notifications"]="Notifications", ["notify"]="Show new-message notifications", ["tray"]="Keep micaGO in the system tray", ["theme"]="Theme", ["chatBackground"]="Chat background", ["choose"]="Choose…", ["removeBackground"]="Clear", ["bubbleColor"]="Outgoing bubble color", ["followSystemAccent"]="Follow system accent", ["customBackground"]="Custom image", ["defaultMicaBackground"]="Default Mica background", ["clearCacheButton"]="Clear cache", ["contacts"]="Contacts", ["cache"]="Storage", ["clearCache"]="Clear local message and media cache", ["clear"]="Clear cache", ["details"]="Conversation details", ["participants"]="Participants", ["conversation"]="Conversation", ["sharedMedia"]="Shared media", ["mute"]="Mute notifications", ["pin"]="Pin conversation", ["selectConversation"]="Select a conversation", ["chooseConversation"]="Choose a conversation to start", ["localOnly"]="Messages stay on this device", ["attach"]="Attach", ["send"]="Send", ["edit"]="Edit", ["unsend"]="Unsend", ["delete"]="Delete" }),
        ["zh-Hans"] = Common(new() { ["search"]="搜索会话", ["message"]="信息", ["settings"]="设置", ["connection"]="连接", ["appearance"]="外观", ["language"]="语言", ["notifications"]="通知", ["notify"]="显示新消息通知", ["tray"]="关闭窗口后常驻系统托盘", ["theme"]="主题", ["chatBackground"]="聊天背景", ["choose"]="选择…", ["removeBackground"]="清除", ["bubbleColor"]="发送气泡颜色", ["followSystemAccent"]="跟随系统强调色", ["customBackground"]="自定义图片", ["defaultMicaBackground"]="默认 Mica 背景", ["clearCacheButton"]="清除缓存", ["contacts"]="联系人", ["cache"]="存储", ["clearCache"]="清除本地消息与媒体缓存", ["clear"]="清除缓存", ["details"]="会话详情", ["participants"]="参与者", ["conversation"]="会话", ["sharedMedia"]="共享媒体", ["mute"]="静音通知", ["pin"]="置顶会话", ["selectConversation"]="选择一个会话", ["chooseConversation"]="选择会话以开始", ["localOnly"]="消息保留在这台设备上", ["attach"]="添加附件", ["send"]="发送", ["edit"]="编辑", ["unsend"]="撤回", ["delete"]="删除" }),
        ["zh-Hant"] = Common(new() { ["search"]="搜尋對話", ["message"]="訊息", ["settings"]="設定", ["connection"]="連線", ["appearance"]="外觀", ["language"]="語言", ["notifications"]="通知", ["notify"]="顯示新訊息通知", ["tray"]="關閉視窗後常駐系統匣", ["theme"]="主題", ["chatBackground"]="聊天背景", ["choose"]="選擇…", ["removeBackground"]="清除", ["bubbleColor"]="傳送氣泡色彩", ["followSystemAccent"]="跟隨系統強調色", ["customBackground"]="自訂圖片", ["defaultMicaBackground"]="預設 Mica 背景", ["clearCacheButton"]="清除快取", ["contacts"]="聯絡人", ["cache"]="儲存空間", ["clearCache"]="清除本機訊息與媒體快取", ["clear"]="清除快取", ["details"]="對話詳細資料", ["participants"]="參與者", ["conversation"]="對話", ["sharedMedia"]="共享媒體", ["mute"]="將通知靜音", ["pin"]="置頂對話", ["selectConversation"]="選擇一個對話", ["chooseConversation"]="選擇對話以開始", ["localOnly"]="訊息保留在這台裝置上", ["attach"]="加入附件", ["send"]="傳送", ["edit"]="編輯", ["unsend"]="收回", ["delete"]="刪除" }),
    };

    private static Dictionary<string, string> Common(Dictionary<string, string> values)
    {
        var chinese = values["settings"] != "Settings";
        var traditional = values["settings"] == "設定";
        values["connSubtitle"] = !chinese ? "Connect this Windows PC to your micaGO server" : traditional ? "將這台 Windows 電腦連線到你的 micaGO 伺服器" : "将这台 Windows 电脑连接到你的 micaGO 服务器";
        values["connPairingJson"] = traditional ? "配對 JSON" : chinese ? "配对 JSON" : "Pairing JSON";
        values["connPlaceholder"] = traditional ? "貼上 micaGO Companion 中的配對 JSON" : chinese ? "粘贴 micaGO Companion 中的配对 JSON" : "Paste the pairing JSON from micaGO Companion";
        values["connTokenNote"] = traditional ? "權杖只儲存在 Windows 認證管理員中，不會寫入連線檔案。" : chinese ? "令牌只保存在 Windows 凭据管理器中，不会写入连接文件。" : "The token is stored in Windows Credential Manager and is never written to the connection file.";
        values["connConnect"] = traditional ? "連線" : chinese ? "连接" : "Connect";
        values["connChecking"] = traditional ? "正在檢查已儲存的連線…" : chinese ? "正在检查已保存的连接…" : "Checking the saved connection…";
        values["connPaste"] = traditional ? "貼上配對 JSON 以連線這台電腦。" : chinese ? "粘贴配对 JSON 以连接这台电脑。" : "Paste a pairing JSON to connect this PC.";
        values["connTimeout"] = traditional ? "已儲存連線檢查逾時，請貼上配對 JSON 繼續。" : chinese ? "已保存连接检查超时，请粘贴配对 JSON 继续。" : "Saved connection check timed out. Paste a pairing JSON to continue.";
        values["connTesting"] = traditional ? "正在測試線路…" : chinese ? "正在测试线路…" : "Testing routes…";
        values["connRestoreFailed"] = traditional ? "無法還原已儲存的連線：{0}" : chinese ? "无法恢复已保存的连接：{0}" : "The saved connection could not be restored: {0}";
        values["twemojiFlags"] = traditional ? "使用 Twemoji 顯示旗幟" : chinese ? "使用 Twemoji 显示旗帜" : "Use Twemoji for flags";
        values["twemojiFlagsDescription"] = traditional ? "開啟時以 SVG 替換旗幟；Emoji 17 會一律使用內建向量圖作為 Windows 缺字備援。" : chinese ? "开启时以 SVG 替换旗帜；Emoji 17 始终使用内置矢量图作为 Windows 缺字兜底。" : "When enabled, flags use SVG artwork. Emoji 17 always uses bundled vectors as a Windows fallback.";
        values["twemojiAttribution"] = traditional ? "Twemoji 圖形 © Twitter, Inc. 與貢獻者 · CC-BY 4.0" : chinese ? "Twemoji 图形 © Twitter, Inc. 与贡献者 · CC-BY 4.0" : "Twemoji graphics © Twitter, Inc. and contributors · CC-BY 4.0";
        values["twemojiDisclaimer"] = traditional ? "這是獨立的相容性選項。micaGO 與 X Corp. 或 Twitter 無隸屬、認可、贊助或背書關係。" : chinese ? "这是独立的兼容性选项。micaGO 与 X Corp. 或 Twitter 不存在隶属、认可、赞助或背书关系。" : "Independent compatibility option. micaGO is not affiliated with, endorsed by, or sponsored by X Corp. or Twitter.";
        values["select"] = traditional ? "選取" : chinese ? "选择" : "Select";
        values["forward"] = traditional ? "轉發" : chinese ? "转发" : "Forward";
        values["forwardTo"] = traditional ? "轉發到…" : chinese ? "转发到…" : "Forward to…";
        values["hide"] = traditional ? "隱藏" : chinese ? "隐藏" : "Hide";
        values["hiddenContacts"] = traditional ? "隱藏的聯絡人" : chinese ? "隐藏的联系人" : "Hidden contacts";
        values["hiddenMessages"] = traditional ? "隱藏的訊息" : chinese ? "隐藏的消息" : "Hidden messages";
        values["hiddenMessagesCount"] = traditional ? "已隱藏 {0} 則訊息" : chinese ? "已隐藏 {0} 条消息" : "{0} messages hidden";
        values["noHiddenMessages"] = traditional ? "沒有隱藏的訊息" : chinese ? "没有隐藏的消息" : "No hidden messages";
        values["releasedMessages"] = traditional ? "已還原 {0} 則隱藏訊息" : chinese ? "已恢复 {0} 条隐藏消息" : "Restored {0} hidden messages";
        values["you"] = traditional ? "你" : chinese ? "你" : "You";
        values["hiddenContactsCount"] = traditional ? "已隱藏 {0} 個聯絡人" : chinese ? "已隐藏 {0} 个联系人" : "{0} contacts hidden";
        values["noHiddenContacts"] = traditional ? "沒有隱藏的聯絡人" : chinese ? "没有隐藏的联系人" : "No hidden contacts";
        values["restoreSelected"] = traditional ? "還原所選項目" : chinese ? "恢复所选项目" : "Restore selected";
        values["releasedContacts"] = traditional ? "已還原 {0} 個隱藏的聯絡人" : chinese ? "已恢复 {0} 个隐藏的联系人" : "Restored {0} hidden contacts";
        values["selectAll"] = traditional ? "全選" : chinese ? "全选" : "Select all";
        values["selectedCount"] = traditional ? "已選取 {0} 則訊息" : chinese ? "已选择 {0} 条消息" : "{0} selected";
        values["voiceMessage"] = traditional ? "語音訊息" : chinese ? "语音消息" : "Voice message";
        values["emoji"] = traditional ? "表情符號" : chinese ? "表情符号" : "Emoji";
        values["jumpToBottom"] = traditional ? "跳到最新訊息" : chinese ? "跳到最新消息" : "Jump to latest";
        values["testing"] = traditional ? "測試" : chinese ? "测试" : "Testing";
        values["testContact"] = traditional ? "離線測試聯絡人" : chinese ? "离线测试联系人" : "Offline test contact";
        values["testContactHint"] = traditional ? "在伺服器上建立一個永不送達的本機迴環聯絡人，用於測試訊息流程。" : chinese ? "在服务器上创建一个永不送达的本机回环联系人，用于测试消息流程。" : "Creates a loopback contact on the server that never delivers anywhere, for testing the message pipeline.";
        values["backupRestore"] = traditional ? "備份與還原" : chinese ? "备份与恢复" : "Backup & restore";
        values["backupLabel"] = traditional ? "設定備份（.micagobak）— 不含權杖與連線資料" : chinese ? "设置备份（.micagobak）— 不含令牌与连接资料" : "Settings backup (.micagobak) — never includes the token or connection";
        values["exportBackup"] = traditional ? "匯出…" : chinese ? "导出…" : "Export…";
        values["importBackup"] = traditional ? "匯入…" : chinese ? "导入…" : "Import…";
        values["backupSaved"] = traditional ? "已匯出 {0} 項設定。" : chinese ? "已导出 {0} 项设置。" : "Exported {0} settings.";
        values["backupRestored"] = traditional ? "已還原 {0} 項設定。" : chinese ? "已恢复 {0} 项设置。" : "Restored {0} settings.";
        values["backupFailed"] = traditional ? "備份操作失敗：{0}" : chinese ? "备份操作失败：{0}" : "Backup operation failed: {0}";
        values["routes"] = traditional ? "路由" : chinese ? "路由" : "Routes";
        values["mergeRoutes"] = traditional ? "合併此聯絡人的全部路由" : chinese ? "合并此联系人的全部路由" : "Merge all routes of this contact";
        values["sendUsing"] = traditional ? "傳送時使用" : chinese ? "发送时使用" : "Send using";
        values["general"] = traditional ? "一般" : chinese ? "通用" : "General";
        values["data"] = traditional ? "資料" : chinese ? "数据" : "Data";
        values["trayDescription"] = traditional ? "關閉主視窗後仍在背景接收即時訊息" : chinese ? "关闭主窗口后仍在后台接收实时消息" : "Keep receiving live messages after the main window closes";
        values["allowSms"] = traditional ? "允許透過 Mac 傳送 SMS" : chinese ? "允许通过 Mac 发送短信" : "Allow SMS sending through the Mac";
        values["allowSmsDescription"] = traditional ? "此開關儲存在伺服器上；預設關閉，iMessage 不受影響。" : chinese ? "此开关保存在服务器上；默认关闭，iMessage 不受影响。" : "Stored on the server and off by default; iMessage is unaffected.";
        values["notificationDescription"] = traditional ? "僅在 micaGO 執行期間顯示 Windows 原生通知" : chinese ? "仅在 micaGO 运行期间显示 Windows 原生通知" : "Show native Windows notifications only while micaGO is running";
        values["notificationPreview"] = traditional ? "在通知中顯示訊息內容" : chinese ? "在通知中显示消息内容" : "Show message text in notifications";
        values["notificationPreviewDescription"] = traditional ? "關閉後，通知只顯示寄件者與「新訊息」。" : chinese ? "关闭后，通知只显示发送者和“新消息”。" : "When off, notifications show the sender and “New message” only.";
        values["notificationHistorySilent"] = traditional ? "每次啟動後的第一輪歷史同步保持靜默；建立基線後收到的新訊息才會通知。" : chinese ? "每次启动后的第一轮历史同步保持静默；建立基线后收到的新消息才会通知。" : "The first history sync after each launch stays silent. New messages notify after that baseline is established.";
        values["cacheLabel"] = traditional ? "媒體與訊息快取" : chinese ? "媒体与消息缓存" : "Media and message cache";
        values["clearCacheTitle"] = traditional ? "清除本機快取？" : chinese ? "清除本地缓存？" : "Clear local cache?";
        values["clearCacheConfirm"] = traditional ? "本機訊息與媒體副本會被移除，下次同步時重新下載。" : chinese ? "本地消息与媒体副本会被移除，下次同步时重新下载。" : "Local message and media copies will be removed and downloaded again during sync.";
        values["cacheCleared"] = traditional ? "已清除本機快取。" : chinese ? "已清除本地缓存。" : "Local cache cleared.";
        values["developer"] = traditional ? "開發人員" : chinese ? "开发人员" : "Developer";
        values["newMessage"] = traditional ? "新訊息" : chinese ? "新消息" : "New message";
        values["customColor"] = traditional ? "自訂色彩" : chinese ? "自定义颜色" : "Custom color";
        values["about"] = traditional ? "關於" : chinese ? "关于" : "About";
        values["aboutSubtitle"] = traditional ? "iMessage 的 Windows 伴侶用戶端" : chinese ? "iMessage 的 Windows 伴侣客户端" : "The Windows companion client for iMessage";
        values["version"] = traditional ? "版本 {0} · Iolite" : chinese ? "版本 {0} · Iolite" : "Version {0} · Iolite";
        values["viewOnGitHub"] = traditional ? "在 GitHub 上檢視專案" : chinese ? "在 GitHub 上查看项目" : "View the project on GitHub";
        values["openSource"] = traditional ? "開源與致謝" : chinese ? "开源与致谢" : "Open source & attributions";
        // C74: GitHub release update check.
        values["checkUpdates"] = traditional ? "檢查更新" : chinese ? "检查更新" : "Check for updates";
        values["updateCheckNow"] = traditional ? "點按檢查最新版本" : chinese ? "点按检查最新版本" : "Check GitHub for a newer release";
        values["updateCheckButton"] = traditional ? "立即檢查" : chinese ? "立即检查" : "Check now";
        values["updateChecking"] = traditional ? "正在檢查…" : chinese ? "正在检查…" : "Checking…";
        values["updateUpToDate"] = traditional ? "已是最新版本" : chinese ? "已是最新版本" : "Up to date";
        values["updateAvailable"] = traditional ? "有新版本 {0}" : chinese ? "有新版本 {0}" : "Version {0} is available";
        values["updateUnknown"] = traditional ? "檢查失敗，請稍後再試" : chinese ? "检查失败，请稍后重试" : "Check failed — try again later";
        values["updateOpen"] = traditional ? "開啟發行頁" : chinese ? "打开发布页" : "Open release";
        return values;
    }

    public string Language { get; private set; } = ResolveSystemLanguage();
    public void SetLanguage(string value) => Language = Tables.ContainsKey(value) ? value : ResolveSystemLanguage();
    public string this[string key] => VcfStrings.TryGetValue(Language, out var vcf) && vcf.TryGetValue(key, out var special) ? special : Tables.TryGetValue(Language, out var table) && table.TryGetValue(key, out var value) ? value : Tables["en"].GetValueOrDefault(key, key);
    private static string ResolveSystemLanguage() { var name = CultureInfo.CurrentUICulture.Name; return name.StartsWith("zh-Hant", StringComparison.OrdinalIgnoreCase) || name is "zh-TW" or "zh-HK" or "zh-MO" ? "zh-Hant" : name.StartsWith("zh", StringComparison.OrdinalIgnoreCase) ? "zh-Hans" : "en"; }
}

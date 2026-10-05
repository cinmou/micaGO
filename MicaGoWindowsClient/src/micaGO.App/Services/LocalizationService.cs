using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace MicaGo.App.Services;

public sealed class LocalizationService
{
    private static readonly IReadOnlyDictionary<string, IReadOnlyDictionary<string, string>> VcfStrings = new Dictionary<string, IReadOnlyDictionary<string, string>>
    {
        ["en"] = new Dictionary<string, string> { ["contactsHint"]="Match message addresses with one or more vCard files. Photos inside the cards are saved on this PC.", ["importVcf"]="Import contacts from vCard (.vcf)", ["chooseVcf"]="Choose files…", ["clearContacts"]="Clear all", ["clearContactsTitle"]="Clear imported contacts?", ["clearContactsConfirm"]="All names and photos imported from vCard files will be removed from this PC.", ["contactsCleared"]="Imported contacts and photos cleared.", ["cancel"]="Cancel", ["importingVcf"]="Importing vCard contacts…", ["vcfImported"]="Imported {0} contacts across {1} addresses; skipped {2} cards.", ["vcfImportFailed"]="vCard import failed: {0}" },
        ["zh-Hans"] = new Dictionary<string, string> { ["contactsHint"]="用一个或多个 vCard 文件匹配消息地址，名片里的头像会保存在这台电脑上。", ["importVcf"]="从 vCard（.vcf）导入联系人", ["chooseVcf"]="选择文件…", ["clearContacts"]="全部清除", ["clearContactsTitle"]="清除已导入的联系人？", ["clearContactsConfirm"]="从 vCard 导入的所有姓名和头像都将从这台电脑移除。", ["contactsCleared"]="已清除导入的联系人和头像。", ["cancel"]="取消", ["importingVcf"]="正在导入 vCard 联系人…", ["vcfImported"]="已导入 {0} 位联系人、{1} 个地址；跳过 {2} 张名片。", ["vcfImportFailed"]="vCard 导入失败：{0}" },
        ["zh-Hant"] = new Dictionary<string, string> { ["contactsHint"]="用一個或多個 vCard 檔案比對訊息地址，名片裡的頭像會儲存在這台電腦上。", ["importVcf"]="從 vCard（.vcf）匯入聯絡人", ["chooseVcf"]="選擇檔案…", ["clearContacts"]="全部清除", ["clearContactsTitle"]="清除已匯入的聯絡人？", ["clearContactsConfirm"]="從 vCard 匯入的所有姓名與頭像都會從這台電腦移除。", ["contactsCleared"]="已清除匯入的聯絡人與頭像。", ["cancel"]="取消", ["importingVcf"]="正在匯入 vCard 聯絡人…", ["vcfImported"]="已匯入 {0} 位聯絡人、{1} 個地址；略過 {2} 張名片。", ["vcfImportFailed"]="vCard 匯入失敗：{0}" },
    };
    private static readonly IReadOnlyDictionary<string, IReadOnlyDictionary<string, string>> Tables = new Dictionary<string, IReadOnlyDictionary<string, string>>
    {
        ["en"] = Common(new() { ["search"]="Search conversations", ["message"]="Message", ["settings"]="Settings", ["connection"]="Connection", ["appearance"]="Appearance", ["language"]="Language", ["notifications"]="Notifications", ["notify"]="Show new-message notifications", ["tray"]="Keep micaGO in the system tray", ["theme"]="Theme", ["chatBackground"]="Chat background", ["choose"]="Choose…", ["removeBackground"]="Clear", ["bubbleColor"]="Outgoing bubble color", ["followSystemAccent"]="Follow system accent", ["customBackground"]="Custom image", ["defaultMicaBackground"]="Default Mica background", ["clearCacheButton"]="Clear cache", ["contacts"]="Contacts", ["cache"]="Storage", ["clearCache"]="Clear the local cache", ["clear"]="Clear cache", ["details"]="Conversation details", ["participants"]="Participants", ["conversation"]="Conversation", ["sharedMedia"]="Shared media", ["mute"]="Mute notifications", ["pin"]="Pin conversation", ["selectConversation"]="Select a conversation", ["chooseConversation"]="Choose a conversation to start", ["attach"]="Attach", ["send"]="Send", ["edit"]="Edit", ["unsend"]="Unsend", ["delete"]="Delete" }),
        ["zh-Hans"] = Common(new() { ["search"]="搜索会话", ["message"]="信息", ["settings"]="设置", ["connection"]="连接", ["appearance"]="外观", ["language"]="语言", ["notifications"]="通知", ["notify"]="显示新消息通知", ["tray"]="关闭窗口后常驻系统托盘", ["theme"]="主题", ["chatBackground"]="聊天背景", ["choose"]="选择…", ["removeBackground"]="清除", ["bubbleColor"]="发送气泡颜色", ["followSystemAccent"]="跟随系统强调色", ["customBackground"]="自定义图片", ["defaultMicaBackground"]="默认 Mica 背景", ["clearCacheButton"]="清除缓存", ["contacts"]="联系人", ["cache"]="存储", ["clearCache"]="清除本地缓存", ["clear"]="清除缓存", ["details"]="会话详情", ["participants"]="参与者", ["conversation"]="会话", ["sharedMedia"]="共享媒体", ["mute"]="静音通知", ["pin"]="置顶会话", ["selectConversation"]="选择一个会话", ["chooseConversation"]="选择会话以开始", ["attach"]="添加附件", ["send"]="发送", ["edit"]="编辑", ["unsend"]="撤回", ["delete"]="删除" }),
        ["zh-Hant"] = Common(new() { ["search"]="搜尋對話", ["message"]="訊息", ["settings"]="設定", ["connection"]="連線", ["appearance"]="外觀", ["language"]="語言", ["notifications"]="通知", ["notify"]="顯示新訊息通知", ["tray"]="關閉視窗後常駐系統匣", ["theme"]="主題", ["chatBackground"]="聊天背景", ["choose"]="選擇…", ["removeBackground"]="清除", ["bubbleColor"]="傳送氣泡色彩", ["followSystemAccent"]="跟隨系統強調色", ["customBackground"]="自訂圖片", ["defaultMicaBackground"]="預設 Mica 背景", ["clearCacheButton"]="清除快取", ["contacts"]="聯絡人", ["cache"]="儲存空間", ["clearCache"]="清除本機快取", ["clear"]="清除快取", ["details"]="對話詳細資料", ["participants"]="參與者", ["conversation"]="對話", ["sharedMedia"]="共享媒體", ["mute"]="將通知靜音", ["pin"]="置頂對話", ["selectConversation"]="選擇一個對話", ["chooseConversation"]="選擇對話以開始", ["attach"]="加入附件", ["send"]="傳送", ["edit"]="編輯", ["unsend"]="收回", ["delete"]="刪除" }),
    };

    private static Dictionary<string, string> Common(Dictionary<string, string> values)
    {
        var chinese = values["settings"] != "Settings";
        var traditional = values["settings"] == "設定";
        values["prefsDescription"] = traditional ? "隱藏的聊天會同步到其他裝置。" : chinese ? "隐藏的聊天会同步到其他设备。" : "Hidden chats sync to your other devices.";
        values["prefsOffline"] = chinese ? (traditional ? "尚未同步，連線後重試。" : "尚未同步，连接后重试。") : "Not synced yet. Retry when connected.";
        values["prefsConflict"] = traditional ? "其他裝置改過隱藏狀態，請選擇保留哪一份。" : chinese ? "其他设备改过隐藏状态，请选择保留哪一份。" : "Another device changed which chats are hidden. Pick the version to keep.";
        values["prefsError"] = chinese ? (traditional ? "恢復訊息失敗，請重試。" : "恢复消息失败，请重试。") : "Could not restore messages. Please retry.";
        values["prefsConnect"] = chinese ? (traditional ? "請先連線至伺服器。" : "请先连接至服务器。") : "Connect to the server first.";
        values["prefsImport"] = traditional ? "同步這台電腦上的隱藏記錄（{0}）" : chinese ? "同步这台电脑上的隐藏记录（{0}）" : "Sync hidden chats from this PC ({0})";
        values["prefsRetry"] = chinese ? (traditional ? "重試同步" : "重试同步") : "Retry sync";
        values["prefsServer"] = chinese ? (traditional ? "保留伺服器設定" : "保留服务器设置") : "Keep server settings";
        values["prefsMine"] = chinese ? (traditional ? "套用我的修改" : "应用我的修改") : "Apply my changes";
        values["notificationReply"] = traditional ? "回覆" : chinese ? "回复" : "Reply";
        values["notificationReplyPending"] = traditional ? "傳送狀態待確認，請開啟 micaGO 檢查後再重送。" : chinese ? "发送状态待确认，请打开 micaGO 检查后再重发。" : "Delivery is awaiting confirmation. Open micaGO to check before resending.";
        values["notificationReplyRejected"] = traditional ? "無法使用此通知回覆，請開啟 micaGO 檢查連線。" : chinese ? "无法使用此通知回复，请打开 micaGO 检查连接。" : "This notification cannot send a reply. Open micaGO to check the connection.";
        values["notificationReplyFailed"] = traditional ? "無法傳送回覆，請開啟 micaGO 傳送訊息。" : chinese ? "无法发送回复，请打开 micaGO 发送消息。" : "Reply could not be sent. Open micaGO to send your message.";
        values["markRead"] = traditional ? "標為已讀" : chinese ? "标为已读" : "Mark as read";
        values["markUnread"] = traditional ? "標為未讀" : chinese ? "标为未读" : "Mark as unread";
        values["undo"] = traditional ? "復原" : chinese ? "撤销" : "Undo";
        values["chatHidden"] = traditional ? "對話已隱藏" : chinese ? "会话已隐藏" : "Conversation hidden";
        values["tokenRejectedTitle"] = traditional ? "裝置權杖遭拒" : chinese ? "设备令牌被拒绝" : "Device credential rejected";
        values["tokenRejectedBody"] = traditional ? "此裝置已無權存取伺服器，請使用 Mac 上的新配對碼重新連線。" : chinese ? "此设备已无权访问服务器，请使用 Mac 上的新配对码重新连接。" : "This device no longer has access to the server. Pair again using a new code from the Mac.";
        values["pairAgain"] = traditional ? "重新配對" : chinese ? "重新配对" : "Pair again";
        values["scanQr"] = traditional ? "掃描配對碼" : chinese ? "扫描配对码" : "Scan pairing code";
        values["qrImage"] = traditional ? "選擇 QR Code 圖片" : chinese ? "选择二维码图片" : "Choose QR image";
        values["qrHint"] = traditional ? "使用攝影機掃描 Mac 配對碼，或選擇 QR Code 圖片。也可繼續使用 JSON 配對。" : chinese ? "使用摄像头扫描 Mac 配对码，或选择二维码图片。也可继续使用 JSON 配对。" : "Scan the Mac pairing code with a camera, or choose its image. JSON pairing remains available.";
        values["cameraUnavailable"] = traditional ? "無法使用攝影機，請檢查攝影機權限或選擇 QR Code 圖片。" : chinese ? "无法使用摄像头，请检查摄像头权限或选择二维码图片。" : "Camera unavailable. Check camera permissions or choose a QR image.";
        values["qrNotFound"] = traditional ? "圖片中未找到有效的配對碼。" : chinese ? "图片中未找到有效的配对码。" : "No valid pairing code found in this image.";
        values["scanStarting"] = traditional ? "正在啟動攝影機…" : chinese ? "正在启动摄像头…" : "Starting camera…";
        values["qrRead"] = traditional ? "已辨識配對碼，點選「連線」開始配對。" : chinese ? "已识别配对码，点击“连接”开始配对。" : "Pairing code read. Select Connect to pair.";
        values["connSubtitle"] = !chinese ? "Connect this Windows PC to your micaGO server" : traditional ? "將這台 Windows 電腦連線到你的 micaGO 伺服器" : "将这台 Windows 电脑连接到你的 micaGO 服务器";
        values["connPairingJson"] = traditional ? "配對 JSON" : chinese ? "配对 JSON" : "Pairing JSON";
        values["connPlaceholder"] = traditional ? "貼上 micaGO Companion 中的配對 JSON" : chinese ? "粘贴 micaGO Companion 中的配对 JSON" : "Paste the pairing JSON from micaGO Companion";
        values["connTokenNote"] = traditional ? "權杖只儲存在 Windows 認證管理員中。" : chinese ? "令牌只保存在 Windows 凭据管理器中。" : "The token is saved only in Windows Credential Manager.";
        values["connConnect"] = traditional ? "連線" : chinese ? "连接" : "Connect";
        values["connChecking"] = traditional ? "正在檢查已儲存的連線…" : chinese ? "正在检查已保存的连接…" : "Checking the saved connection…";
        values["connPaste"] = traditional ? "貼上配對 JSON 以連線這台電腦。" : chinese ? "粘贴配对 JSON 以连接这台电脑。" : "Paste a pairing JSON to connect this PC.";
        values["connTimeout"] = traditional ? "檢查已儲存的連線逾時，請貼上配對 JSON 繼續。" : chinese ? "检查已保存的连接超时，请粘贴配对 JSON 继续。" : "Checking the saved connection took too long. Paste a pairing JSON to continue.";
        values["connTesting"] = traditional ? "正在測試線路…" : chinese ? "正在测试线路…" : "Testing routes…";
        values["connRestoreFailed"] = traditional ? "無法還原已儲存的連線：{0}" : chinese ? "无法恢复已保存的连接：{0}" : "The saved connection could not be restored: {0}";
        values["twemojiFlags"] = traditional ? "使用 Twemoji 顯示旗幟" : chinese ? "使用 Twemoji 显示旗帜" : "Use Twemoji for flags";
        values["twemojiFlagsDescription"] = traditional ? "用 Twemoji 圖片顯示旗幟。Windows 缺少 Emoji 17 字形，這部分一律使用內建圖片。" : chinese ? "用 Twemoji 图片显示旗帜。Windows 缺少 Emoji 17 字形，这部分始终使用内置图片。" : "Shows flags as Twemoji images. Emoji 17 always uses built-in images because Windows lacks them.";
        values["twemojiAttribution"] = traditional ? "Twemoji 圖形 © Twitter, Inc. 與貢獻者 · CC-BY 4.0" : chinese ? "Twemoji 图形 © Twitter, Inc. 与贡献者 · CC-BY 4.0" : "Twemoji graphics © Twitter, Inc. and contributors · CC-BY 4.0";
        values["twemojiDisclaimer"] = traditional ? "micaGO 與 X Corp.（Twitter）沒有任何關係。" : chinese ? "micaGO 与 X Corp.（Twitter）没有任何关系。" : "micaGO has no affiliation with X Corp. (Twitter).";
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
        values["testContactHint"] = traditional ? "在伺服器上新增一個測試聊天，傳到這裡的訊息不會離開 Mac。" : chinese ? "在服务器上添加一个测试聊天，发到这里的消息不会离开 Mac。" : "Adds a test chat on the server. Messages sent there never leave the Mac.";
        values["backupRestore"] = traditional ? "備份與還原" : chinese ? "备份与恢复" : "Backup & restore";
        values["backupLabel"] = traditional ? "設定備份（.micagobak），不含權杖或連線資料" : chinese ? "设置备份（.micagobak），不含令牌或连接信息" : "Settings backup (.micagobak), without the token or connection details";
        values["exportBackup"] = traditional ? "匯出…" : chinese ? "导出…" : "Export…";
        values["importBackup"] = traditional ? "匯入…" : chinese ? "导入…" : "Import…";
        values["backupSaved"] = traditional ? "已匯出 {0} 項設定。" : chinese ? "已导出 {0} 项设置。" : "Exported {0} settings.";
        values["backupRestored"] = traditional ? "已還原 {0} 項設定。" : chinese ? "已恢复 {0} 项设置。" : "Restored {0} settings.";
        values["backupFailed"] = traditional ? "備份操作失敗：{0}" : chinese ? "备份操作失败：{0}" : "Backup operation failed: {0}";
        values["routes"] = traditional ? "帳號與合併" : chinese ? "账号与合并" : "Accounts & merging";
        values["mergeRoutes"] = traditional ? "合併此聯絡人的對話" : chinese ? "合并此联系人的对话" : "Merge this contact’s conversations";
        values["mergeNeedsContact"] = traditional ? "匯入包含此人的電話與電子郵件的 .vcf 聯絡人卡片，才能將不同帳號的對話合併。" : chinese ? "导入包含此人号码和邮箱的 .vcf 联系人卡片，才能将不同账号的对话合并。" : "Import a .vcf contact card containing this person’s phone numbers and emails to merge their conversations.";
        values["mergeSingleRoute"] = traditional ? "目前只找到此聯絡人的一個對話帳號。其他帳號的對話出現後可在這裡合併。" : chinese ? "目前只找到此联系人的一个对话账号。其他账号的对话出现后可在这里合并。" : "Only one conversation account was found for this contact. More accounts can be merged here when their conversations appear.";
        values["sendUsing"] = traditional ? "傳送時使用" : chinese ? "发送时使用" : "Send using";
        values["general"] = traditional ? "一般" : chinese ? "通用" : "General";
        values["data"] = traditional ? "資料" : chinese ? "数据" : "Data";
        values["trayDescription"] = traditional ? "關閉視窗後繼續接收訊息" : chinese ? "关闭窗口后继续接收消息" : "Keep receiving messages after you close the window";
        values["allowSms"] = traditional ? "允許透過 Mac 傳送 SMS" : chinese ? "允许通过 Mac 发送短信" : "Allow SMS sending through the Mac";
        values["allowSmsDescription"] = traditional ? "儲存在伺服器上，預設關閉，不影響 iMessage。" : chinese ? "保存在服务器上，默认关闭，不影响 iMessage。" : "Saved on the server and off by default. iMessage isn't affected.";
        values["notificationDescription"] = traditional ? "僅在 micaGO 執行時顯示" : chinese ? "仅在 micaGO 运行时显示" : "Only while micaGO is running";
        values["notificationPreview"] = traditional ? "在通知中顯示訊息內容" : chinese ? "在通知中显示消息内容" : "Show message text in notifications";
        values["notificationPreviewDescription"] = traditional ? "關閉後，通知只顯示寄件者與「新訊息」。" : chinese ? "关闭后，通知只显示发送者和“新消息”。" : "When off, notifications show the sender and “New message” only.";
        values["cacheLabel"] = traditional ? "本機快取" : chinese ? "本地缓存" : "Local cache";
        values["clearCacheTitle"] = traditional ? "清除本機快取？" : chinese ? "清除本地缓存？" : "Clear local cache?";
        values["clearCacheConfirm"] = traditional ? "本機快取會被刪除，下次同步時重新下載。" : chinese ? "本地缓存会被删除，下次同步时重新下载。" : "The local cache is removed and downloads again on the next sync.";
        values["cacheCleared"] = traditional ? "已清除本機快取。" : chinese ? "已清除本地缓存。" : "Local cache cleared.";
        values["developer"] = traditional ? "開發人員" : chinese ? "开发人员" : "Developer";
        values["newMessage"] = traditional ? "新訊息" : chinese ? "新消息" : "New message";
        values["customColor"] = traditional ? "自訂色彩" : chinese ? "自定义颜色" : "Custom color";
        // W-UI8: bubble colour presets (names match the Flutter theme colours).
        values["presetColors"] = traditional ? "預設色彩" : chinese ? "预设颜色" : "Preset colors";
        values["color.micago"] = "micaGO";
        values["color.bicao"] = chinese ? "碧草" : "Bicao";
        values["color.wisteria"] = chinese ? "紫藤" : "Wisteria";
        values["color.citrus"] = chinese ? "柑橘" : "Citrus";
        values["color.inkWash"] = chinese ? "水墨" : "Ink wash";
        values["color.paleGold"] = traditional ? "淺金" : chinese ? "浅金" : "Pale gold";
        values["color.wineRed"] = traditional ? "酒紅" : chinese ? "酒红" : "Wine red";
        values["color.blueGreen"] = traditional ? "藍綠" : chinese ? "蓝绿" : "Blue green";
        values["color.indigo"] = traditional ? "靛藍" : chinese ? "靛蓝" : "Indigo";
        values["color.peachBlossom"] = chinese ? "桃花" : "Peach blossom";
        values["color.witheredGrass"] = chinese ? "枯草" : "Withered grass";
        values["color.amber"] = chinese ? "琥珀" : "Amber";
        // W-UI9: route card + unpair (Flutter C85/C76).
        values["route"] = traditional ? "伺服器路線" : chinese ? "服务器线路" : "Server route";
        values["routeChecking"] = traditional ? "檢查中…" : chinese ? "检测中…" : "Checking…";
        values["routeAvailable"] = chinese ? "可用" : "Available";
        values["routeUnavailable"] = traditional ? "無法使用" : chinese ? "不可用" : "Unavailable";
        values["routeConnected"] = traditional ? "已連線" : chinese ? "已连接" : "Connected";
        values["routeConnecting"] = traditional ? "正在連線…" : chinese ? "正在连接…" : "Connecting…";
        values["routeSwitching"] = traditional ? "正在切換…" : chinese ? "正在切换…" : "Switching…";
        values["routeSwitchedToast"] = traditional ? "已切換到這條路線，斷線時會自動換路線" : chinese ? "已切换到这条线路，断开时会自动换线路" : "Switched to this route. If it drops, micaGO changes routes automatically.";
        values["routeFellBackToast"] = traditional ? "這條路線連不上，已自動換到其他路線" : chinese ? "这条线路连不上，已自动换到其他线路" : "This route didn't connect, so micaGO switched to another one.";
        values["routeSwitchFailedToast"] = traditional ? "這條路線連不上" : chinese ? "这条线路连不上" : "This route can't connect.";
        values["unpair"] = traditional ? "解除配對並清除資料" : chinese ? "解除配对并清除数据" : "Unpair and clear data";
        values["unpairDescription"] = traditional ? "移除已儲存的伺服器、權杖和本機快取" : chinese ? "移除已保存的服务器、令牌和本地缓存" : "Removes the saved server, the token, and the local cache";
        values["unpairTitle"] = traditional ? "解除這台電腦的配對？" : chinese ? "解除这台电脑的配对？" : "Unpair this PC?";
        values["unpairBody"] = traditional ? "這會刪除已儲存的伺服器位址、Windows 認證管理員中的權杖，以及這台電腦的本機快取。Mac 上的訊息不受影響，隨時可以重新配對。" : chinese ? "这会删除已保存的服务器地址、Windows 凭据管理器中的令牌，以及这台电脑的本地缓存。Mac 上的消息不受影响，随时可以重新配对。" : "This removes the saved server address, the token in Windows Credential Manager, and this PC's local cache. Messages on your Mac stay as they are, and you can pair again at any time.";
        values["unpairConfirm"] = traditional ? "解除配對" : chinese ? "解除配对" : "Unpair";
        // W-UI10: strings that used to be hardcoded English.
        values["back"] = traditional ? "返回" : chinese ? "返回" : "Back";
        values["retry"] = traditional ? "重試" : chinese ? "重试" : "Retry";
        values["cancelUpload"] = traditional ? "取消上傳" : chinese ? "取消上传" : "Cancel upload";
        values["close"] = traditional ? "關閉" : chinese ? "关闭" : "Close";
        values["saveAs"] = traditional ? "另存新檔" : chinese ? "另存为" : "Save as";
        values["openWith"] = traditional ? "開啟方式" : chinese ? "打开方式" : "Open with";
        values["themeSystem"] = traditional ? "跟隨系統" : chinese ? "跟随系统" : "System";
        values["themeLight"] = traditional ? "淺色" : chinese ? "浅色" : "Light";
        values["themeDark"] = traditional ? "深色" : chinese ? "深色" : "Dark";
        values["credentialsUnavailable"] = traditional ? "Windows 認證管理員無法使用。" : chinese ? "Windows 凭据管理器不可用。" : "Windows Credential Manager is unavailable.";
        values["serverUnreachable"] = traditional ? "連不上伺服器。" : chinese ? "连不上服务器。" : "Couldn't reach the server.";
        values["chatWindowFailed"] = traditional ? "已連線，但無法開啟聊天畫面：{0}" : chinese ? "已连接，但无法打开聊天界面：{0}" : "Connected, but the chat window couldn't open: {0}";
        values["initFailed"] = traditional ? "載入失敗：{0}" : chinese ? "加载失败：{0}" : "Couldn't load: {0}";
        values["pasteFailed"] = traditional ? "無法貼上附件：{0}" : chinese ? "无法粘贴附件：{0}" : "Couldn't paste the attachment: {0}";
        values["micUnavailable"] = traditional ? "麥克風無法使用：{0}" : chinese ? "麦克风不可用：{0}" : "Microphone unavailable: {0}";
        values["statusConnected"] = traditional ? "已連線" : chinese ? "已连接" : "Connected";
        values["statusLive"] = traditional ? "即時" : chinese ? "实时" : "Live";
        values["statusCatchingUp"] = traditional ? "正在同步" : chinese ? "正在同步" : "Catching up";
        values["statusReconnecting"] = traditional ? "正在重新連線" : chinese ? "正在重连" : "Reconnecting";
        values["statusOfflineCache"] = traditional ? "離線快取" : chinese ? "离线缓存" : "Offline cache";
        values["about"] = traditional ? "關於" : chinese ? "关于" : "About";
        values["aboutSubtitle"] = traditional ? "透過你的 Mac 在 Windows 上使用 iMessage" : chinese ? "通过你的 Mac 在 Windows 上使用 iMessage" : "iMessage on Windows, through your Mac";
        values["version"] = traditional ? "版本 {0} · Muscovite" : chinese ? "版本 {0} · Muscovite" : "Version {0} · Muscovite";
        values["viewOnGitHub"] = traditional ? "在 GitHub 上檢視專案" : chinese ? "在 GitHub 上查看项目" : "View the project on GitHub";
        values["openSource"] = traditional ? "開源與致謝" : chinese ? "开源与致谢" : "Open source & attributions";
        // C74: GitHub release update check.
        values["checkUpdates"] = traditional ? "檢查更新" : chinese ? "检查更新" : "Check for updates";
        values["updateCheckNow"] = traditional ? "點按檢查最新版本" : chinese ? "点按检查最新版本" : "Check GitHub for a newer release";
        values["updateCheckButton"] = traditional ? "立即檢查" : chinese ? "立即检查" : "Check now";
        values["updateChecking"] = traditional ? "正在檢查…" : chinese ? "正在检查…" : "Checking…";
        values["updateUpToDate"] = traditional ? "已是最新版本" : chinese ? "已是最新版本" : "Up to date";
        values["updateAvailable"] = traditional ? "有新版本 {0}" : chinese ? "有新版本 {0}" : "Version {0} is available";
        values["updateUnknown"] = traditional ? "檢查失敗，請稍後再試" : chinese ? "检查失败，请稍后重试" : "Check failed. Try again later.";
        values["updateOpen"] = traditional ? "開啟發行頁" : chinese ? "打开发布页" : "Open release";
        return values;
    }

    public string Language { get; private set; } = ResolveSystemLanguage();
    public event EventHandler? LanguageChanged;
    public void SetLanguage(string value)
    {
        var language = Tables.ContainsKey(value) ? value : ResolveSystemLanguage();
        if (Language == language) return;
        Language = language;
        LanguageChanged?.Invoke(this, EventArgs.Empty);
    }

    public void ApplyTypography(FrameworkElement root)
    {
        // Bind Han glyph selection to our language picker, including unpackaged hosts.
        // Keep Latin and emoji native while supplying an explicit Chinese fallback.
        var traditional = Language == "zh-Hant";
        root.Language = Language switch { "zh-Hans" => "zh-CN", "zh-Hant" => "zh-TW", _ => "en-US" };
        var font = new FontFamily(traditional
            ? "Segoe UI, Microsoft JhengHei UI, Microsoft JhengHei, Microsoft YaHei UI"
            : "Segoe UI, Microsoft YaHei UI, Microsoft YaHei, Microsoft JhengHei UI");
        Application.Current.Resources["ContentControlThemeFontFamily"] = font;
        if (root is Control control) control.FontFamily = font;
    }
    public string this[string key] => VcfStrings.TryGetValue(Language, out var vcf) && vcf.TryGetValue(key, out var special) ? special : Tables.TryGetValue(Language, out var table) && table.TryGetValue(key, out var value) ? value : Tables["en"].GetValueOrDefault(key, key);
    private static string ResolveSystemLanguage() { var name = CultureInfo.CurrentUICulture.Name; return name.StartsWith("zh-Hant", StringComparison.OrdinalIgnoreCase) || name is "zh-TW" or "zh-HK" or "zh-MO" ? "zh-Hant" : name.StartsWith("zh", StringComparison.OrdinalIgnoreCase) ? "zh-Hans" : "en"; }
}

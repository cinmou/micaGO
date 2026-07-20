using System.Globalization;

namespace MicaGo.App.Services;

public sealed class LocalizationService
{
    private static readonly IReadOnlyDictionary<string, IReadOnlyDictionary<string, string>> VcfStrings = new Dictionary<string, IReadOnlyDictionary<string, string>>
    {
        ["en"] = new Dictionary<string, string> { ["contactsHint"]="Match message handles with Google Contacts or a vCard exported from another app.", ["importVcf"]="Import contacts from vCard (.vcf)", ["importingVcf"]="Importing vCard contacts…", ["vcfImported"]="Imported {0} contacts across {1} addresses; skipped {2} cards.", ["vcfImportFailed"]="vCard import failed: {0}" },
        ["zh-Hans"] = new Dictionary<string, string> { ["contactsHint"]="使用 Google 通讯录或从其他应用导出的 vCard 匹配消息地址。", ["importVcf"]="从 vCard（.vcf）导入联系人", ["importingVcf"]="正在导入 vCard 联系人…", ["vcfImported"]="已导入 {0} 位联系人、{1} 个地址；跳过 {2} 张名片。", ["vcfImportFailed"]="vCard 导入失败：{0}" },
        ["zh-Hant"] = new Dictionary<string, string> { ["contactsHint"]="使用 Google 聯絡人或從其他 App 匯出的 vCard 比對訊息地址。", ["importVcf"]="從 vCard（.vcf）匯入聯絡人", ["importingVcf"]="正在匯入 vCard 聯絡人…", ["vcfImported"]="已匯入 {0} 位聯絡人、{1} 個地址；略過 {2} 張名片。", ["vcfImportFailed"]="vCard 匯入失敗：{0}" },
    };
    private static readonly IReadOnlyDictionary<string, IReadOnlyDictionary<string, string>> Tables = new Dictionary<string, IReadOnlyDictionary<string, string>>
    {
        ["en"] = Common(new() { ["search"]="Search conversations", ["message"]="Message", ["settings"]="Settings", ["connection"]="Connection", ["appearance"]="Appearance", ["language"]="Language", ["notifications"]="Notifications", ["notify"]="Show new-message notifications", ["tray"]="Keep micaGO in the system tray", ["theme"]="Theme", ["chatBackground"]="Chat background", ["choose"]="Choose…", ["removeBackground"]="Clear", ["bubbleColor"]="Outgoing bubble color", ["followSystemAccent"]="Follow system accent", ["customBackground"]="Custom image", ["defaultMicaBackground"]="Default Mica background", ["clearCacheButton"]="Clear cache", ["contacts"]="Contacts", ["contactsHint"]="Match message handles with Google Contacts or an existing CSV export on this PC.", ["importCsv"]="Import contacts from CSV", ["importingCsv"]="Importing contacts…", ["csvImported"]="Imported {0} contacts across {1} addresses; skipped {2} rows.", ["csvImportFailed"]="CSV import failed: {0}", ["signInGoogle"]="Sign in with Google", ["cache"]="Storage", ["clearCache"]="Clear local message and media cache", ["clear"]="Clear cache", ["details"]="Conversation details", ["participants"]="Participants", ["conversation"]="Conversation", ["sharedMedia"]="Shared media", ["mute"]="Mute notifications", ["pin"]="Pin conversation", ["selectConversation"]="Select a conversation", ["chooseConversation"]="Choose a conversation to start", ["localOnly"]="Messages stay on this device", ["attach"]="Attach", ["send"]="Send", ["edit"]="Edit", ["unsend"]="Unsend", ["delete"]="Delete" }),
        ["zh-Hans"] = Common(new() { ["search"]="搜索会话", ["message"]="信息", ["settings"]="设置", ["connection"]="连接", ["appearance"]="外观", ["language"]="语言", ["notifications"]="通知", ["notify"]="显示新消息通知", ["tray"]="关闭窗口后常驻系统托盘", ["theme"]="主题", ["chatBackground"]="聊天背景", ["choose"]="选择…", ["removeBackground"]="清除", ["bubbleColor"]="发送气泡颜色", ["followSystemAccent"]="跟随系统强调色", ["customBackground"]="自定义图片", ["defaultMicaBackground"]="默认 Mica 背景", ["clearCacheButton"]="清除缓存", ["contacts"]="联系人", ["contactsHint"]="使用 Google 通讯录或这台电脑上的 CSV 导出文件匹配消息地址。", ["importCsv"]="从 CSV 导入联系人", ["importingCsv"]="正在导入联系人…", ["csvImported"]="已导入 {0} 位联系人、{1} 个地址；跳过 {2} 行。", ["csvImportFailed"]="CSV 导入失败：{0}", ["signInGoogle"]="登录 Google", ["cache"]="存储", ["clearCache"]="清除本地消息与媒体缓存", ["clear"]="清除缓存", ["details"]="会话详情", ["participants"]="参与者", ["conversation"]="会话", ["sharedMedia"]="共享媒体", ["mute"]="静音通知", ["pin"]="置顶会话", ["selectConversation"]="选择一个会话", ["chooseConversation"]="选择会话以开始", ["localOnly"]="消息保留在这台设备上", ["attach"]="添加附件", ["send"]="发送", ["edit"]="编辑", ["unsend"]="撤回", ["delete"]="删除" }),
        ["zh-Hant"] = Common(new() { ["search"]="搜尋對話", ["message"]="訊息", ["settings"]="設定", ["connection"]="連線", ["appearance"]="外觀", ["language"]="語言", ["notifications"]="通知", ["notify"]="顯示新訊息通知", ["tray"]="關閉視窗後常駐系統匣", ["theme"]="主題", ["chatBackground"]="聊天背景", ["choose"]="選擇…", ["removeBackground"]="清除", ["bubbleColor"]="傳送氣泡色彩", ["followSystemAccent"]="跟隨系統強調色", ["customBackground"]="自訂圖片", ["defaultMicaBackground"]="預設 Mica 背景", ["clearCacheButton"]="清除快取", ["contacts"]="聯絡人", ["contactsHint"]="使用 Google 聯絡人或這台電腦上的 CSV 匯出檔比對訊息地址。", ["importCsv"]="從 CSV 匯入聯絡人", ["importingCsv"]="正在匯入聯絡人…", ["csvImported"]="已匯入 {0} 位聯絡人、{1} 個地址；略過 {2} 列。", ["csvImportFailed"]="CSV 匯入失敗：{0}", ["signInGoogle"]="登入 Google", ["cache"]="儲存空間", ["clearCache"]="清除本機訊息與媒體快取", ["clear"]="清除快取", ["details"]="對話詳細資料", ["participants"]="參與者", ["conversation"]="對話", ["sharedMedia"]="共享媒體", ["mute"]="將通知靜音", ["pin"]="置頂對話", ["selectConversation"]="選擇一個對話", ["chooseConversation"]="選擇對話以開始", ["localOnly"]="訊息保留在這台裝置上", ["attach"]="加入附件", ["send"]="傳送", ["edit"]="編輯", ["unsend"]="收回", ["delete"]="刪除" }),
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
        return values;
    }

    public string Language { get; private set; } = ResolveSystemLanguage();
    public void SetLanguage(string value) => Language = Tables.ContainsKey(value) ? value : ResolveSystemLanguage();
    public string this[string key] => VcfStrings.TryGetValue(Language, out var vcf) && vcf.TryGetValue(key, out var special) ? special : Tables.TryGetValue(Language, out var table) && table.TryGetValue(key, out var value) ? value : Tables["en"].GetValueOrDefault(key, key);
    private static string ResolveSystemLanguage() { var name = CultureInfo.CurrentUICulture.Name; return name.StartsWith("zh-Hant", StringComparison.OrdinalIgnoreCase) || name is "zh-TW" or "zh-HK" or "zh-MO" ? "zh-Hant" : name.StartsWith("zh", StringComparison.OrdinalIgnoreCase) ? "zh-Hans" : "en"; }
}

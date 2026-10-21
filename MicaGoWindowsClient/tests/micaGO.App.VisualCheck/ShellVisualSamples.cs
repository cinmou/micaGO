using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using MicaGo.Core.Models;

namespace MicaGo.App.Views;

public sealed partial class ShellPage
{
    internal void LoadVisualSamples()
    {
        Loaded -= ShellPage_Loaded;
        RequestedTheme = ElementTheme.Dark;
        ApplyLocalizedText();
        var chat = new ChatSummary("sample", "林晓 · 两个账号", "中英文混排与气泡布局", "刚刚", 0, "林", CanSendText: true);
        ChatList.ItemsSource = new[] {
            chat,
            new ChatSummary("second", "设计讨论", "字号、间距与层次", "10:24", 3, "设", IsGroup: true, HasUnread: true),
            new ChatSummary("third", "Alex Chen", "Windows 字体与主题", "昨天", 0, "AC"),
        };
        ChatList.SelectedItem = chat;
        ThreadTitle.Text = chat.Title;
        ThreadSubtitle.Text = "刚刚";
        ThreadAvatar.DisplayName = chat.Title;
        ConnectionStatusText.Text = "界面预览 · 本地样例";
        EmptyState.Visibility = Visibility.Collapsed;
        Composer.IsEnabled = true;
        var texts = new[] {
            ("这版把文字、间距和背景层次统一了。", false),
            ("输入框参考 Flutter，保留中文输入和原生焦点。", true),
            ("简体中文与繁體中文 · Segoe UI Variable\nEnglish, 0123456789，标点与 emoji 👋", false),
            ("长消息会按窗口宽度换行，不会把最后一行挤掉。调整字号后，行高也能随字形变化。", true),
            ("关联邮箱和号码后，历史放在同一条会话里。", false),
            ("好的 👍", true),
        };
        MessageList.ItemsSource = texts.Select((sample, index) => new MessageRow(new Message(
            index.ToString(), "sample", sample.Item1, "10:30", sample.Item2, MessageDeliveryState.Delivered))).ToArray();
        Loaded+=(_,_)=>RunShellChecks(chat);
        if (Environment.GetEnvironmentVariable("MICAGO_RECYCLE_CHECK") == "1")
            Loaded += (_, _) => RunRecycleCheck();
    }

    private void RunShellChecks(ChatSummary chat)
    {
        var timer=new DispatcherTimer{Interval=TimeSpan.FromMilliseconds(800)};
        var results=new List<string>();var pass=0;
        timer.Tick+=(_,_)=>{
            UpdateLayout();
            if(pass++==0) {
                chat.UpdateFrom(chat with{Preview="本地发送预览已即时更新"});
                ApplyConnectionStatusVisibility(false);return;
            }
            if(pass==2) {
            results.Add($"{(ConnectionStatusRow.ActualHeight==0&&ConnectionStatusPanel.Visibility==Visibility.Collapsed?"PASS":"FAIL")} hidden connection state occupies zero height");
            var container=ChatList.ContainerFromItem(chat) as DependencyObject;
            var found=container is not null&&FindText(container,"本地发送预览已即时更新");
            results.Add($"{(found?"PASS":"FAIL")} existing chat preview binding updates without replacing row");
            ApplyConnectionStatusVisibility(true);return;
            }
            results.Add($"{(Math.Abs(ConnectionStatusRow.ActualHeight-38)<=1/(XamlRoot?.RasterizationScale??1)?"PASS":"FAIL")} connection state restores standard height ({ConnectionStatusRow.ActualHeight:F3})");
            results.Add($"{(MessageList.AllowDrop?"PASS":"FAIL")} message canvas accepts native drag/drop");
            File.WriteAllLines(Path.Combine(AppContext.BaseDirectory,"shell-check.log"),results);timer.Stop();
        };timer.Start();
    }
    private static bool FindText(DependencyObject element,string text)
    {
        if(element is TextBlock block&&block.Text==text)return true;
        for(var i=0;i<Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(element);i++)
            if(FindText(Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(element,i),text))return true;
        return false;
    }

    private void RunRecycleCheck()
    {
        // Regression: ordinary history containers have no Translation facade yet.
        ResetMessageVisual(new Border());
        var original = MessageList.ItemsSource;
        var recycled = 0;
        MessageList.ContainerContentChanging += (_, args) => { if (args.InRecycleQueue) recycled++; };
        var cycle = 0;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(200) };
        timer.Tick += (_, _) =>
        {
            MessageList.ItemsSource = Enumerable.Range(0, 200).Select(index => new MessageRow(new Message(
                $"{cycle}:{index}", $"chat-{cycle % 2}", $"回收检查 {cycle}/{index} · 中文与 English · 多条消息", "10:30", index % 2 == 0, MessageDeliveryState.Delivered))).ToArray();
            MessageList.UpdateLayout();
            _messageScroller?.ChangeView(null, cycle % 2 == 0 ? _messageScroller.ScrollableHeight : 0, null, true);
            if (++cycle < 18) return;
            timer.Stop();
            MessageList.ItemsSource = original;
            MessageList.UpdateLayout();
            File.WriteAllText(Path.Combine(AppContext.BaseDirectory, "recycle-check.log"),
                $"{(recycled > 0 ? "PASS" : "FAIL")} unanimated visual reset; 18 conversation switches x 200 messages; {recycled} recycled containers");
        };
        timer.Start();
    }
}

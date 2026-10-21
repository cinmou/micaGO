using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using MicaGo.App.Controls;
using MicaGo.App.Services;
using MicaGo.Core.Models;

namespace MicaGo.App;

// Opt-in, offline rendering probe: no saved pairing, network or notifications.
// Build the app with -p:MicaGoVisualCheck=true. The normal client excludes this file.
internal static class VisualCheck
{
    private static Window? _window;
    private static Window? _shellWindow;

    public static void Run()
    {
        if(Environment.GetEnvironmentVariable("MICAGO_ABOUT_CHECK")=="1"){Views.AboutVisualCheck.Run();return;}
        AppServices.Current.Localization.SetLanguage("zh-Hans");
        var root = new Grid { Padding = new Thickness(24), ColumnSpacing = 24 };
        AppServices.Current.Localization.ApplyTypography(root);
        root.ColumnDefinitions.Add(new ColumnDefinition());
        root.ColumnDefinitions.Add(new ColumnDefinition());
        var samples = new List<(MessageBubble Bubble, RichTextBlock Body, Border Card, bool Outgoing, bool Scaled)>();
        for (var column = 0; column < 2; column++)
        {
            var pane = new StackPanel { Spacing = 12, Padding = new Thickness(16), RequestedTheme = column == 0 ? ElementTheme.Light : ElementTheme.Dark };
            // Theme-aware brushes are resolved in each element's scope.
            var border = new Border { Child = new ScrollViewer { Content = pane, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled }, CornerRadius = new CornerRadius(8), RequestedTheme = pane.RequestedTheme };
            border.Background = new SolidColorBrush(column == 0 ? Microsoft.UI.Colors.WhiteSmoke : Microsoft.UI.ColorHelper.FromArgb(255,32,32,32));
            Grid.SetColumn(border, column); root.Children.Add(border);
            pane.Children.Add(new TextBlock { Text = column == 0 ? "浅色 · 字体与气泡" : "深色 · 字体与气泡", FontSize = 20 });
            foreach (var (text, outgoing, scaled) in new[] {
                ("简体中文、繁體中文与 English 0123456789", false, false),
                ("发送的文字始终清晰可见。Agjpqy 中文标点：，。！？", true, false),
                ("长消息自动换行。\n第二行包含表情 👨‍👩‍👧‍👦 🫩 🇨🇳 与中文。", false, false),
                ("放大文字：Agjpqy 简体繁體 🫩", false, true),
            })
            {
                var message = new Message(Guid.NewGuid().ToString(), "visual-check", text, "10:30", outgoing, MessageDeliveryState.Delivered);
                var bubble = new MessageBubble { Message = message, HorizontalAlignment = HorizontalAlignment.Stretch };
                pane.Children.Add(bubble);
                var body = (RichTextBlock)bubble.FindName("BodyText");
                if (scaled) body.FontSize = 28;
                samples.Add((bubble, body, (Border)bubble.FindName("Bubble"), outgoing, scaled));
            }
            pane.Children.Add(new TextBox { PlaceholderText = "输入中文 / English…", FontSize = 16, MinHeight = 48, CornerRadius = new CornerRadius(24), AcceptsReturn = true, TextWrapping = TextWrapping.Wrap });
        }
        _window = new Window { Title = "micaGO Visual Check", Content = root, SystemBackdrop = new MicaBackdrop { Kind = MicaKind.Base } };
        _window.AppWindow.Resize(new Windows.Graphics.SizeInt32(1100, 820));
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(700) };
        var pass = 0;
        var results = new List<string>();
        timer.Tick += (_, _) =>
        {
            root.UpdateLayout();
            foreach (var sample in samples)
            {
                var body = sample.Body;
                var color = (body.Foreground as SolidColorBrush)?.Color;
                var fill = (sample.Card.Background as SolidColorBrush)?.Color;
                var valid = body.ActualWidth > 0 && body.ActualHeight >= (sample.Scaled ? 28 : 20)
                    && color is not null && fill is not null && color.Value != fill.Value;
                if (!sample.Outgoing && color is { } ink)
                    valid &= body.ActualTheme == ElementTheme.Dark ? ink.R > 128 : ink.R < 128;
                results.Add($"{(valid ? "PASS" : "FAIL")} theme={body.ActualTheme} outgoing={sample.Outgoing} scaled={sample.Scaled} size={body.ActualWidth:F1}x{body.ActualHeight:F1} text={color} fill={fill}");
            }
            if (pass++ == 0)
            {
                // Force an in-place theme switch; existing rows must update.
                foreach (var child in root.Children.OfType<Border>())
                {
                    var next = child.RequestedTheme == ElementTheme.Light ? ElementTheme.Dark : ElementTheme.Light;
                    child.RequestedTheme = next;
                    ((FrameworkElement)((ScrollViewer)child.Child).Content).RequestedTheme = next;
                    child.Background = new SolidColorBrush(next == ElementTheme.Light ? Microsoft.UI.Colors.WhiteSmoke : Microsoft.UI.ColorHelper.FromArgb(255,32,32,32));
                }
                return;
            }
            timer.Stop();
            File.WriteAllLines(Path.Combine(AppContext.BaseDirectory, "visual-check.log"), results);
        };
        root.Loaded += (_, _) => timer.Start();
        _window.Activate();
        var shell = new Views.ShellPage();
        shell.LoadVisualSamples();
        AppServices.Current.Localization.ApplyTypography(shell);
        _shellWindow = new Window { Title = "micaGO Shell Preview", Content = shell, SystemBackdrop = new MicaBackdrop { Kind = MicaKind.Base } };
        _shellWindow.AppWindow.Resize(new Windows.Graphics.SizeInt32(1500, 1100));
        _shellWindow.Activate();
    }
}

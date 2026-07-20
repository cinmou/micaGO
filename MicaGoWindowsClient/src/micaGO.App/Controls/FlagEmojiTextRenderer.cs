using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media.Imaging;
using MicaGo.Core.Models;

namespace MicaGo.App.Controls;

internal static class FlagEmojiTextRenderer
{
    public static void SetText(TextBlock target, string text, double iconSize, bool replaceFlags)
    {
        try
        {
            target.Inlines.Clear();
            var segments = FlagEmojiSemantics.Split(text, replaceFlags, includeEmoji17: true);
            foreach (var segment in segments)
            {
                if (!segment.HasAsset)
                {
                    target.Inlines.Add(new Run { Text = segment.Text });
                    continue;
                }

                var folder = segment.IsEmoji17 ? "TwemojiEmoji17" : "TwemojiFlags";
                target.Inlines.Add(new InlineUIContainer
                {
                    Child = new Image
                    {
                        Width = iconSize,
                        Height = iconSize,
                        Margin = new Thickness(1, 0, 1, -Math.Max(1, iconSize * 0.08)),
                        Stretch = Microsoft.UI.Xaml.Media.Stretch.Uniform,
                        Source = new SvgImageSource(new Uri($"ms-appx:///Assets/{folder}/{segment.AssetKey}.svg")),
                        IsHitTestVisible = false,
                    },
                });
            }
        }
        catch
        {
            // A malformed third-party asset must never take down the message
            // surface. Fall back to the platform glyph for this text block.
            target.Inlines.Clear();
            target.Inlines.Add(new Run { Text = text });
        }
    }
}

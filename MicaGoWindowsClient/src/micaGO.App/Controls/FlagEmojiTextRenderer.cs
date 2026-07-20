using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media.Imaging;
using MicaGo.Core.Models;

namespace MicaGo.App.Controls;

/// <summary>
/// Renders message text with Twemoji SVGs substituted for flag / Emoji-17
/// sequences. The target must be a RichTextBlock: WinUI's plain TextBlock
/// silently rejects InlineUIContainer, which is why flags used to fall back
/// to bare regional-indicator letters.
/// </summary>
internal static class FlagEmojiTextRenderer
{
    public static void SetText(RichTextBlock target, string text, double iconSize, bool replaceFlags)
    {
        var paragraph = new Paragraph();
        try
        {
            var segments = FlagEmojiSemantics.Split(text, replaceFlags, includeEmoji17: true);
            foreach (var segment in segments)
            {
                if (!segment.HasAsset)
                {
                    paragraph.Inlines.Add(new Run { Text = segment.Text });
                    continue;
                }

                var folder = segment.IsEmoji17 ? "TwemojiEmoji17" : "TwemojiFlags";
                var source = new SvgImageSource(new Uri($"ms-appx:///Assets/{folder}/{segment.AssetKey}.svg"));
                var image = new Image
                {
                    Width = iconSize,
                    Height = iconSize,
                    Margin = new Thickness(1, 0, 1, -Math.Max(1, iconSize * 0.08)),
                    Stretch = Microsoft.UI.Xaml.Media.Stretch.Uniform,
                    Source = source,
                    IsHitTestVisible = false,
                };
                var container = new InlineUIContainer { Child = image };
                // SvgImageSource fails asynchronously (a missing asset never
                // reaches the catch below) — swap the platform glyph back in so
                // an unmapped sequence renders as text instead of a blank gap.
                var fallbackText = segment.Text;
                source.OpenFailed += (_, _) =>
                {
                    container.Child = new TextBlock
                    {
                        Text = fallbackText,
                        FontSize = iconSize,
                        IsHitTestVisible = false,
                    };
                };
                paragraph.Inlines.Add(container);
            }
        }
        catch
        {
            // A malformed third-party asset must never take down the message
            // surface. Fall back to the platform glyphs for this block.
            paragraph = new Paragraph();
            paragraph.Inlines.Add(new Run { Text = text });
        }

        target.Blocks.Clear();
        target.Blocks.Add(paragraph);
    }
}

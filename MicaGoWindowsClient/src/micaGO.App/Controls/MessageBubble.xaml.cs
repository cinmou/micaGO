using System.Globalization;
using System.Text.RegularExpressions;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using MicaGo.App.Services;
using MicaGo.Core.Models;
using Windows.Storage;
using Windows.Storage.Streams;

namespace MicaGo.App.Controls;

/// <summary>
/// One chat row. Rendering rules mirror the Flutter client: media renders as
/// bubble-less blocks above the text bubble (captioned media = two visual
/// siblings), big-emoji and sticker-only messages drop the bubble entirely,
/// the sender label sits above the bubble and the delivery footer below it.
/// Every property is reset on each bind so ListView container recycling can
/// never leak state between rows.
/// </summary>
public sealed partial class MessageBubble : UserControl
{
    private const double MediaMaxWidth = 320;
    private const double MediaMaxHeight = 306;
    private const double StickerMaxSize = 180;
    private const int ThumbnailCacheLimit = 96;
    private static readonly Dictionary<string, BitmapImage> ThumbnailCache = [];
    private static readonly LinkedList<string> ThumbnailLru = [];
    private static readonly object ThumbnailGate = new();

    // Transient per-thread presentation state (mirrors the Flutter client's
    // entrance tracker / invisible-ink reveal / footer transition memory).
    // Reset by the shell whenever another chat is opened.
    private static readonly HashSet<string> SeenEntranceKeys = [];
    private static readonly HashSet<string> RevealedInkKeys = [];
    private static readonly Dictionary<string, string> FooterMemory = [];
    private static readonly Dictionary<string, string?> LinkTitleCache = [];
    private static readonly HttpClient LinkHttp = new() { Timeout = TimeSpan.FromSeconds(5) };
    private static readonly Regex UrlRegex = new(
        @"https?://[^\s<>""']+", RegexOptions.Compiled | RegexOptions.IgnoreCase);
    private static DateTime _threadOpenedAt = DateTime.MinValue;

    /// <summary>Raised when a reply preview is tapped; payload is the target message guid.</summary>
    public static event EventHandler<string>? ReplyJumpRequested;

    /// <summary>Raised when a full-screen send effect should play; payload is the effect id.</summary>
    public static event EventHandler<string>? ScreenEffectRequested;

    private static event EventHandler? AppearanceChanged;

    public static void RefreshAppearance() => AppearanceChanged?.Invoke(null, EventArgs.Empty);

    /// <summary>Called by the shell when a chat is opened, so history rows never animate.</summary>
    public static void ResetTransientState()
    {
        SeenEntranceKeys.Clear();
        FooterMemory.Clear();
        _threadOpenedAt = DateTime.UtcNow;
    }

    private static bool InThreadOpenGracePeriod =>
        (DateTime.UtcNow - _threadOpenedAt) < TimeSpan.FromMilliseconds(700);

    private Message? _message;

    public MessageBubble()
    {
        InitializeComponent();
        DataContextChanged += OnDataContextChanged;
        Loaded += (_, _) => AppearanceChanged += OnAppearanceChanged;
        Unloaded += (_, _) => AppearanceChanged -= OnAppearanceChanged;
    }

    private void OnAppearanceChanged(object? sender, EventArgs e)
    {
        if (_message is not { } message || message.IsSeparator || message.IsPresentationSystem) return;
        var body = MessageSemantics.VisibleText(message.Text);
        ApplyBubble(message, body, body.Length > 0, message.Media.Count > 0, message.IsOutgoing);
    }

    private void OnDataContextChanged(FrameworkElement sender, DataContextChangedEventArgs args)
    {
        if (args.NewValue is not Message message)
        {
            return;
        }

        _message = message;

        if (message.IsSeparator)
        {
            SeparatorChip.Visibility = Visibility.Visible;
            SeparatorText.Text = message.SeparatorLabel ?? string.Empty;
            SystemText.Visibility = Visibility.Collapsed;
            MessageRow.Visibility = Visibility.Collapsed;
            Root.Margin = new Thickness(16, 0, 16, 0);
            return;
        }

        SeparatorChip.Visibility = Visibility.Collapsed;

        if (message.IsPresentationSystem)
        {
            SystemText.Visibility = Visibility.Visible;
            SystemText.Text = (message.GroupTitle ?? "Conversation updated")
                + (message.MergedSystemCount > 1 ? $" · {message.MergedSystemCount}" : string.Empty);
            MessageRow.Visibility = Visibility.Collapsed;
            Root.Margin = new Thickness(16, 2, 16, 2);
            return;
        }

        SystemText.Visibility = Visibility.Collapsed;
        MessageRow.Visibility = Visibility.Visible;
        Root.Margin = new Thickness(
            16,
            message.CompactWithPrevious ? 1 : 3,
            16,
            message.CompactWithNext ? 1 : 3);

        var outgoing = message.IsOutgoing;
        var body = MessageSemantics.VisibleText(message.Text);
        var hasBody = body.Length > 0;
        var hasMedia = message.Media.Count > 0;

        ResetTransientVisuals();
        ApplyDirection(outgoing);
        ApplySenderRow(message, outgoing);
        ApplyReply(message);
        ApplyBubble(message, body, hasBody, hasMedia, outgoing);
        BuildMediaPanel(message, hasMedia, hasBody);
        ApplyLinkPreview(message, body);
        ApplyReactions(message, outgoing);
        ApplyEffectAndFooter(message, outgoing);
        ApplyPendingOverlays(message);
        ApplyInvisibleInk(message);
        ApplyTimestampToolTip(message);
        PlayEntranceIfNew(message);
    }

    /// <summary>Recycled containers must never keep a previous row's animation state.</summary>
    private void ResetTransientVisuals()
    {
        BubbleTransform.ScaleX = 1;
        BubbleTransform.ScaleY = 1;
        BubbleTransform.Rotation = 0;
        BubbleTransform.TranslateY = 0;
        EntranceTransform.Y = 0;
        ContentColumn.Opacity = 1;
        FooterText.Opacity = 1;
    }

    private void ApplyDirection(bool outgoing)
    {
        var side = outgoing ? HorizontalAlignment.Right : HorizontalAlignment.Left;
        ContentColumn.HorizontalAlignment = side;
        BubbleStack.HorizontalAlignment = side;
        Bubble.HorizontalAlignment = side;
        MediaPanel.HorizontalAlignment = side;
        ReplyPanel.HorizontalAlignment = side;
        EffectRow.HorizontalAlignment = side;
        FooterText.HorizontalAlignment = side;
        FooterText.TextAlignment = outgoing ? TextAlignment.Right : TextAlignment.Left;
    }

    private void ApplySenderRow(Message message, bool outgoing)
    {
        AvatarColumn.Width = new GridLength(message.ReserveSenderAvatarSpace ? 28 : 0);

        var senderName = message.SenderName ?? message.SenderIdentity ?? string.Empty;
        var showLabel = !outgoing && message.ShowSenderLabel && !string.IsNullOrWhiteSpace(senderName);
        SenderText.Text = senderName;
        SenderText.Visibility = showLabel ? Visibility.Visible : Visibility.Collapsed;

        SenderAvatar.Visibility = message.ShowSenderAvatar ? Visibility.Visible : Visibility.Collapsed;
        SenderAvatar.DisplayName = senderName;
        SenderAvatar.ProfilePicture = null;
        if (message.ShowSenderAvatar && !string.IsNullOrWhiteSpace(message.SenderAvatarPath))
        {
            _ = LoadAvatarAsync(message);
        }
    }

    private void ApplyReply(Message message)
    {
        var hasReply = !string.IsNullOrWhiteSpace(message.ReplyPreview);
        ReplyPanel.Visibility = hasReply ? Visibility.Visible : Visibility.Collapsed;
        ReplyText.Text = message.ReplyPreview ?? string.Empty;
    }

    private void ApplyBubble(Message message, string body, bool hasBody, bool hasMedia, bool outgoing)
    {
        Bubble.Visibility = hasBody ? Visibility.Visible : Visibility.Collapsed;
        BodyText.Text = body;

        if (message.IsBigEmoji)
        {
            Bubble.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
            Bubble.Padding = new Thickness(2, 6, 2, 6);
            Bubble.CornerRadius = new CornerRadius(0);
            var count = TextElementCount(body);
            BodyText.FontSize = count <= 1 ? 84 : count == 2 ? 64 : 52;
            BodyText.LineHeight = BodyText.FontSize * 1.1;
            BodyText.Foreground = ThemeBrush("TextFillColorPrimaryBrush");
            return;
        }

        Bubble.Padding = new Thickness(12, 7, 12, 8);
        BodyText.FontSize = 14;
        BodyText.LineHeight = 20;
        // Like Flutter's painter: a reacted-to bubble keeps its tail even
        // mid-run, so the chip has an anchor.
        var tail = message.ShowBubbleTail || (message.Reactions?.Count ?? 0) > 0;
        if (outgoing)
        {
            var appearance = AppServices.Current.Appearance;
            if (appearance.BubbleFollowsSystem)
            {
                Bubble.Background = ThemeBrush("AccentFillColorDefaultBrush");
                BodyText.Foreground = ThemeBrush("TextOnAccentFillColorPrimaryBrush");
            }
            else
            {
                Bubble.Background = new SolidColorBrush(appearance.BubbleColor);
                BodyText.Foreground = new SolidColorBrush(
                    AppearanceService.ShouldUseDarkText(appearance.BubbleColor)
                        ? Windows.UI.Color.FromArgb(0xFF, 0x00, 0x00, 0x00)
                        : Windows.UI.Color.FromArgb(0xFF, 0xFF, 0xFF, 0xFF));
            }
            Bubble.CornerRadius = tail ? new CornerRadius(18, 18, 4, 18) : new CornerRadius(18);
        }
        else
        {
            Bubble.Background = ThemeBrush("MicaGoIncomingMessageBrush");
            BodyText.Foreground = ThemeBrush("TextFillColorPrimaryBrush");
            Bubble.CornerRadius = tail ? new CornerRadius(18, 18, 18, 4) : new CornerRadius(18);
        }
    }

    // ----- media -----

    private void BuildMediaPanel(Message message, bool hasMedia, bool hasBody)
    {
        MediaPanel.Children.Clear();
        var side = message.IsOutgoing ? HorizontalAlignment.Right : HorizontalAlignment.Left;

        // An interactive iMessage-app balloon without text or media renders as
        // a bubble-less app card (Flutter's _InteractiveAppCard).
        if (!hasMedia && !hasBody && !string.IsNullOrWhiteSpace(message.BalloonBundleId))
        {
            var appCard = CreateCardTile(
                "\uECAA",
                InteractiveAppTitle(message.BalloonBundleId!),
                InteractiveMessageLabel(),
                onTap: null);
            appCard.HorizontalAlignment = side;
            MediaPanel.Children.Add(appCard);
            MediaPanel.Visibility = Visibility.Visible;
            return;
        }

        MediaPanel.Visibility = hasMedia ? Visibility.Visible : Visibility.Collapsed;
        if (!hasMedia)
        {
            return;
        }

        foreach (var attachment in message.Media)
        {
            var tile = CreateAttachmentTile(message, attachment);
            tile.HorizontalAlignment = side;
            MediaPanel.Children.Add(tile);
        }
    }

    private FrameworkElement CreateAttachmentTile(Message message, Attachment attachment)
    {
        if (attachment.IsStickerLike)
        {
            return CreateStickerTile(message, attachment);
        }
        if (attachment.IsImage || attachment.IsVideo)
        {
            return CreateVisualTile(message, attachment);
        }
        if (attachment.IsVoiceMessage || attachment.IsAudio)
        {
            return CreateCardTile(
                attachment.IsVoiceMessage ? "\uE767" : "\uE8D6",
                attachment.IsVoiceMessage ? VoiceMessageLabel() : attachment.FileName,
                SizeLabel(attachment.Size),
                onTap: () => OpenInViewerAsync(message, attachment));
        }
        if (attachment.IsLocation)
        {
            return CreateCardTile("\uE707", SharedLocationLabel(), null,
                onTap: () => OpenLocationAsync(attachment));
        }
        if (attachment.IsLinkPreview)
        {
            return CreateCardTile("\uE71B", attachment.FileName, null,
                onTap: () => LaunchUriAsync(attachment.FileName));
        }
        return CreateCardTile("\uE8A5", attachment.FileName, SizeLabel(attachment.Size),
            onTap: () => OpenFileAsync(attachment));
    }

    private FrameworkElement CreateStickerTile(Message message, Attachment attachment)
    {
        var image = new Image
        {
            MaxWidth = StickerMaxSize,
            MaxHeight = StickerMaxSize,
            Stretch = Stretch.Uniform,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        var host = new Grid { MinWidth = 64, MinHeight = 64 };
        host.Children.Add(image);
        _ = LoadTileImageAsync(message, attachment, (bitmap, fromCache) =>
        {
            image.Source = bitmap;
            if (!fromCache)
            {
                FadeIn(image);
            }
        });
        return host;
    }

    /// <summary>
    /// Photo / video tile: a rounded rectangle filled with the preview bitmap
    /// (Rectangle + ImageBrush gives real rounded clipping), sized to the
    /// bitmap's aspect ratio within the Flutter client's 306 px height cap.
    /// </summary>
    private FrameworkElement CreateVisualTile(Message message, Attachment attachment)
    {
        var surface = new Rectangle
        {
            RadiusX = 14,
            RadiusY = 14,
            Width = 240,
            Height = 170,
            Fill = ThemeBrush("SubtleFillColorSecondaryBrush"),
        };
        var placeholderIcon = new FontIcon
        {
            Glyph = attachment.IsVideo ? "\uE714" : "\uEB9F",
            FontSize = 22,
            Foreground = ThemeBrush("TextFillColorSecondaryBrush"),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };

        var host = new Grid();
        host.Children.Add(surface);
        host.Children.Add(placeholderIcon);

        if (attachment.IsVideo)
        {
            var playBadge = new Border
            {
                Width = 44,
                Height = 44,
                CornerRadius = new CornerRadius(22),
                Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0x99, 0x00, 0x00, 0x00)),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                IsHitTestVisible = false,
                Child = new FontIcon
                {
                    Glyph = "\uE768",
                    FontSize = 16,
                    Foreground = new SolidColorBrush(Microsoft.UI.Colors.White),
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            };
            host.Children.Add(playBadge);
        }

        _ = LoadTileImageAsync(message, attachment, (bitmap, fromCache) =>
        {
            placeholderIcon.Visibility = Visibility.Collapsed;
            var width = bitmap.PixelWidth > 0 ? bitmap.PixelWidth : 4;
            var height = bitmap.PixelHeight > 0 ? bitmap.PixelHeight : 3;
            var scale = Math.Min(1, Math.Min(MediaMaxWidth / width, MediaMaxHeight / height));
            surface.Width = Math.Max(44, width * scale);
            surface.Height = Math.Max(44, height * scale);
            surface.Fill = new ImageBrush { ImageSource = bitmap, Stretch = Stretch.UniformToFill };
            if (!fromCache)
            {
                FadeIn(surface);
            }
        });

        host.Tapped += async (_, _) => await OpenInViewerAsync(message, attachment);
        return host;
    }

    private FrameworkElement CreateCardTile(string glyph, string title, string? subtitle, Func<Task>? onTap)
    {
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Spacing = 1 };
        text.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 13,
            MaxWidth = 220,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        if (!string.IsNullOrWhiteSpace(subtitle))
        {
            text.Children.Add(new TextBlock
            {
                Text = subtitle,
                FontSize = 11,
                Foreground = ThemeBrush("TextFillColorSecondaryBrush"),
            });
        }

        var layout = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        layout.Children.Add(new Border
        {
            Width = 36,
            Height = 36,
            CornerRadius = new CornerRadius(18),
            Background = ThemeBrush("AccentFillColorDefaultBrush"),
            Child = new FontIcon
            {
                Glyph = glyph,
                FontSize = 14,
                Foreground = ThemeBrush("TextOnAccentFillColorPrimaryBrush"),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            },
        });
        layout.Children.Add(text);

        var card = new Border
        {
            MinWidth = 220,
            MaxWidth = 320,
            Padding = new Thickness(12, 10, 14, 10),
            Background = ThemeBrush("CardBackgroundFillColorDefaultBrush"),
            BorderBrush = ThemeBrush("MicaGoSubtleStrokeBrush"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(14),
            Child = layout,
        };
        if (onTap is not null)
        {
            card.Tapped += async (_, _) => { try { await onTap(); } catch { } };
        }
        return card;
    }

    private async Task LoadTileImageAsync(Message message, Attachment attachment, Action<BitmapImage, bool> apply)
    {
        lock (ThumbnailGate)
        {
            if (ThumbnailCache.TryGetValue(attachment.Id, out var cached))
            {
                TouchThumbnail(attachment.Id);
                // Memory hits render directly with no fade (Flutter C51 rule).
                apply(cached, true);
                return;
            }
        }

        try
        {
            var api = AppServices.Current.Connection.Api;
            var path = AppServices.Current.Media.TryGetPath(attachment.Id, preview: true);
            if (path is null)
            {
                if (api is null)
                {
                    return;
                }
                path = await AppServices.Current.Media.GetAsync(api, attachment.Id, preview: true);
            }
            if (_message?.PresentationKey != message.PresentationKey)
            {
                return;
            }
            var file = await StorageFile.GetFileFromPathAsync(path);
            using IRandomAccessStream stream = await file.OpenAsync(FileAccessMode.Read);
            var bitmap = new BitmapImage { DecodePixelWidth = 720 };
            await bitmap.SetSourceAsync(stream);
            lock (ThumbnailGate)
            {
                ThumbnailCache[attachment.Id] = bitmap;
                TouchThumbnail(attachment.Id);
                while (ThumbnailCache.Count > ThumbnailCacheLimit && ThumbnailLru.First is { } oldest)
                {
                    ThumbnailLru.RemoveFirst();
                    ThumbnailCache.Remove(oldest.Value);
                }
            }
            if (_message?.PresentationKey == message.PresentationKey)
            {
                apply(bitmap, false);
            }
        }
        catch { }
    }

    private static void TouchThumbnail(string key)
    {
        ThumbnailLru.Remove(key);
        ThumbnailLru.AddLast(key);
    }

    private async Task OpenInViewerAsync(Message message, Attachment attachment)
    {
        if (AppServices.Current.Connection.Api is null)
        {
            return;
        }
        try
        {
            await MediaViewerService.ShowAsync(XamlRoot, message, attachment);
        }
        catch { }
    }

    private async Task OpenFileAsync(Attachment attachment)
    {
        var api = AppServices.Current.Connection.Api;
        if (api is null)
        {
            return;
        }
        var path = AppServices.Current.Media.TryGetPath(attachment.Id)
            ?? await AppServices.Current.Media.GetAsync(api, attachment.Id);
        await Windows.System.Launcher.LaunchFileAsync(await StorageFile.GetFileFromPathAsync(path));
    }

    private static async Task LaunchUriAsync(string url)
    {
        if (Uri.TryCreate(url, UriKind.Absolute, out var uri))
        {
            await Windows.System.Launcher.LaunchUriAsync(uri);
        }
    }

    // ----- overlays and captions -----

    private void ApplyReactions(Message message, bool outgoing)
    {
        var reactions = message.Reactions ?? [];
        var visible = reactions.Count > 0;
        ReactionChip.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        ReactionText.Text = string.Join(" ", reactions);
        // The chip overlays the bubble's top corner on the side opposite the
        // sender, exactly like the Flutter client's _ReactionChips placement.
        ReactionChip.HorizontalAlignment = outgoing ? HorizontalAlignment.Left : HorizontalAlignment.Right;
        BubbleBlocks.Margin = visible ? new Thickness(0, 10, 0, 0) : new Thickness(0);
    }

    private void ApplyEffectAndFooter(Message message, bool outgoing)
    {
        var effect = message.EffectLabel;
        EffectRow.Visibility = string.IsNullOrWhiteSpace(effect) ? Visibility.Collapsed : Visibility.Visible;
        EffectText.Text = effect ?? string.Empty;

        // C72 approximation: when the footer appears or its label changes on a
        // row the user is already looking at, fade the new label in instead of
        // snapping (the row-height glide is not reproduced).
        var footerLabel = message.ShowFooter ? FooterLabel(message) : string.Empty;
        var previous = FooterMemory.GetValueOrDefault(message.PresentationKey);
        FooterMemory[message.PresentationKey] = footerLabel;
        FooterText.Visibility = message.ShowFooter ? Visibility.Visible : Visibility.Collapsed;
        FooterText.Text = footerLabel;
        if (message.ShowFooter && previous != footerLabel && !InThreadOpenGracePeriod)
        {
            var storyboard = new Storyboard();
            storyboard.Children.Add(Animate(FooterText, "Opacity", 0, 1, 160));
            storyboard.Begin();
        }
    }

    // ----- send effects -----

    private static bool IsInvisibleInk(string? id) =>
        id?.Contains("invisibleink", StringComparison.OrdinalIgnoreCase) == true;

    private static bool IsBubbleEffect(string? id) =>
        id?.Contains("expressivesend", StringComparison.OrdinalIgnoreCase) == true;

    private void ApplyInvisibleInk(Message message)
    {
        var covered = IsInvisibleInk(message.ExpressiveSendStyleId)
            && !RevealedInkKeys.Contains(message.PresentationKey);
        InkCover.Visibility = covered ? Visibility.Visible : Visibility.Collapsed;
    }

    private void InkCover_Tapped(object sender, TappedRoutedEventArgs e)
    {
        if (_message is null)
        {
            return;
        }
        e.Handled = true;
        RevealedInkKeys.Add(_message.PresentationKey);
        InkCover.Visibility = Visibility.Collapsed;
    }

    private void EffectRow_Tapped(object sender, TappedRoutedEventArgs e)
    {
        var id = _message?.ExpressiveSendStyleId;
        if (string.IsNullOrWhiteSpace(id))
        {
            return;
        }
        e.Handled = true;
        if (IsInvisibleInk(id))
        {
            // Tapping the label re-covers the message, like the Flutter client.
            if (_message is { } message)
            {
                RevealedInkKeys.Remove(message.PresentationKey);
                InkCover.Visibility = Visibility.Visible;
            }
            return;
        }
        if (IsBubbleEffect(id))
        {
            PlayBubbleEffect(id);
            return;
        }
        ScreenEffectRequested?.Invoke(this, id);
    }

    private void PlayBubbleEffect(string id)
    {
        BubbleTransform.ScaleX = 1;
        BubbleTransform.ScaleY = 1;
        BubbleTransform.Rotation = 0;
        var storyboard = new Storyboard();
        if (id.Contains("impact", StringComparison.OrdinalIgnoreCase))
        {
            // Slam: drop in oversized and tilted, spring back into place.
            var spring = new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = 0.7 };
            storyboard.Children.Add(Animate(BubbleTransform, "ScaleX", 1.35, 1, 420, ease: spring));
            storyboard.Children.Add(Animate(BubbleTransform, "ScaleY", 1.35, 1, 420, ease: spring));
            storyboard.Children.Add(Animate(BubbleTransform, "Rotation", -4, 0, 420, ease: spring));
        }
        else if (id.Contains("loud", StringComparison.OrdinalIgnoreCase))
        {
            storyboard.Children.Add(Keyframes(BubbleTransform, "ScaleX", (0, 1), (120, 1.3), (260, 0.94), (360, 1.04), (440, 1)));
            storyboard.Children.Add(Keyframes(BubbleTransform, "ScaleY", (0, 1), (120, 1.3), (260, 0.94), (360, 1.04), (440, 1)));
            storyboard.Children.Add(Keyframes(BubbleTransform, "Rotation", (0, 0), (150, 2), (280, -2), (440, 0)));
        }
        else
        {
            // Gentle: rise from tiny.
            storyboard.Children.Add(Animate(BubbleTransform, "ScaleX", 0.6, 1, 480));
            storyboard.Children.Add(Animate(BubbleTransform, "ScaleY", 0.6, 1, 480));
        }
        storyboard.Begin();
    }

    // ----- reply jump / link preview / entrance -----

    private void ReplyPanel_Tapped(object sender, TappedRoutedEventArgs e)
    {
        var target = ThreadPresentation.NormalizeTarget(_message?.ReplyToGuid);
        if (string.IsNullOrWhiteSpace(target))
        {
            return;
        }
        e.Handled = true;
        ReplyJumpRequested?.Invoke(this, target!);
    }

    private void ApplyLinkPreview(Message message, string body)
    {
        LinkPreviewHost.Content = null;
        LinkPreviewHost.Visibility = Visibility.Collapsed;
        if (body.Length == 0 || message.Media.Any(item => item.IsLinkPreview))
        {
            return;
        }
        var matches = UrlRegex.Matches(body);
        if (matches.Count != 1)
        {
            return;
        }
        var url = matches[0].Value.TrimEnd('.', ',', ')', ']', '。', '，');
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri))
        {
            return;
        }

        var titleBlock = new TextBlock
        {
            Text = LinkTitleCache.GetValueOrDefault(url) ?? uri.Host,
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            MaxWidth = 250,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Spacing = 1 };
        text.Children.Add(titleBlock);
        text.Children.Add(new TextBlock
        {
            Text = uri.Host,
            FontSize = 11,
            Foreground = ThemeBrush("TextFillColorSecondaryBrush"),
        });
        var layout = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        layout.Children.Add(new Border
        {
            Width = 36,
            Height = 36,
            CornerRadius = new CornerRadius(18),
            Background = ThemeBrush("SubtleFillColorSecondaryBrush"),
            Child = new FontIcon
            {
                Glyph = "\uE71B",
                FontSize = 14,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            },
        });
        layout.Children.Add(text);
        var card = new Border
        {
            MinWidth = 220,
            MaxWidth = 320,
            Padding = new Thickness(12, 10, 14, 10),
            Background = ThemeBrush("CardBackgroundFillColorDefaultBrush"),
            BorderBrush = ThemeBrush("MicaGoSubtleStrokeBrush"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(14),
            HorizontalAlignment = message.IsOutgoing ? HorizontalAlignment.Right : HorizontalAlignment.Left,
            Child = layout,
        };
        card.Tapped += async (_, _) => await LaunchUriAsync(url);
        LinkPreviewHost.Content = card;
        LinkPreviewHost.Visibility = Visibility.Visible;
        if (!LinkTitleCache.ContainsKey(url))
        {
            _ = LoadLinkTitleAsync(message, url, titleBlock);
        }
    }

    private async Task LoadLinkTitleAsync(Message message, string url, TextBlock titleBlock)
    {
        string? title = null;
        try
        {
            var html = await LinkHttp.GetStringAsync(url);
            var match = Regex.Match(html, @"<title[^>]*>\s*(.*?)\s*</title>",
                RegexOptions.IgnoreCase | RegexOptions.Singleline);
            if (match.Success)
            {
                title = System.Net.WebUtility.HtmlDecode(match.Groups[1].Value).Trim();
                if (title.Length > 120)
                {
                    title = title[..120];
                }
            }
        }
        catch { }
        if (LinkTitleCache.Count > 200)
        {
            LinkTitleCache.Clear();
        }
        LinkTitleCache[url] = string.IsNullOrWhiteSpace(title) ? null : title;
        if (title is { Length: > 0 } && _message?.PresentationKey == message.PresentationKey)
        {
            titleBlock.Text = title;
        }
    }

    private void PlayEntranceIfNew(Message message)
    {
        var key = message.PresentationKey;
        var isNew = SeenEntranceKeys.Add(key);
        if (!isNew || InThreadOpenGracePeriod || message.DateCreated <= 0)
        {
            return;
        }
        var age = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - message.DateCreated;
        if (age is < 0 or > 15000)
        {
            return;
        }
        ContentColumn.Opacity = 0;
        EntranceTransform.Y = 12;
        var storyboard = new Storyboard();
        storyboard.Children.Add(Animate(ContentColumn, "Opacity", 0, 1, 240));
        storyboard.Children.Add(Animate(EntranceTransform, "Y", 12, 0, 240));
        storyboard.Begin();
    }

    private static void FadeIn(UIElement element, int milliseconds = 180)
    {
        element.Opacity = 0;
        var storyboard = new Storyboard();
        storyboard.Children.Add(Animate(element, "Opacity", 0, 1, milliseconds));
        storyboard.Begin();
    }

    private static Timeline Animate(
        DependencyObject target, string property, double from, double to, int milliseconds,
        EasingFunctionBase? ease = null)
    {
        var animation = new DoubleAnimation
        {
            From = from,
            To = to,
            Duration = new Duration(TimeSpan.FromMilliseconds(milliseconds)),
            EasingFunction = ease ?? new CubicEase { EasingMode = EasingMode.EaseOut },
        };
        Storyboard.SetTarget(animation, target);
        Storyboard.SetTargetProperty(animation, property);
        return animation;
    }

    private static Timeline Keyframes(
        DependencyObject target, string property, params (int Ms, double Value)[] frames)
    {
        var animation = new DoubleAnimationUsingKeyFrames();
        foreach (var (ms, value) in frames)
        {
            animation.KeyFrames.Add(new EasingDoubleKeyFrame
            {
                KeyTime = KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(ms)),
                Value = value,
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
            });
        }
        Storyboard.SetTarget(animation, target);
        Storyboard.SetTargetProperty(animation, property);
        return animation;
    }

    private async Task OpenLocationAsync(Attachment attachment)
    {
        var api = AppServices.Current.Connection.Api;
        if (api is null)
        {
            return;
        }
        var path = AppServices.Current.Media.TryGetPath(attachment.Id)
            ?? await AppServices.Current.Media.GetAsync(api, attachment.Id);
        var text = await File.ReadAllTextAsync(path);
        var match = UrlRegex.Match(text);
        if (match.Success)
        {
            await LaunchUriAsync(match.Value);
        }
    }

    private static string InteractiveAppTitle(string bundleId)
    {
        if (bundleId.Contains("Handwriting", StringComparison.OrdinalIgnoreCase))
        {
            return HandwritingLabel();
        }
        if (bundleId.Contains("DigitalTouch", StringComparison.OrdinalIgnoreCase))
        {
            return "Digital Touch";
        }
        var tail = bundleId.Split('.', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? bundleId;
        tail = tail.Replace("MessagesExtension", string.Empty).Replace("MobileSMS", "iMessage");
        return string.IsNullOrWhiteSpace(tail) ? "App" : tail;
    }

    private void ApplyPendingOverlays(Message message)
    {
        var uploading = message.IsPending
            && message.DeliveryState == MessageDeliveryState.Sending
            && message.Media.Count > 0;
        var failed = message.IsPending
            && message.DeliveryState == MessageDeliveryState.Failed
            && message.Media.Count > 0;

        UploadDim.Visibility = uploading ? Visibility.Visible : Visibility.Collapsed;
        UploadRing.Visibility = uploading ? Visibility.Visible : Visibility.Collapsed;
        UploadRing.Value = message.UploadProgress;

        FailedBadge.Visibility = failed ? Visibility.Visible : Visibility.Collapsed;
        FailedText.Text = NotDeliveredLabel();
        BubbleBlocks.Opacity = failed ? 0.55 : 1;
    }

    private void ApplyTimestampToolTip(Message message)
    {
        if (message.DateCreated <= 0)
        {
            ToolTipService.SetToolTip(BubbleStack, null);
            return;
        }
        var stamp = DateTimeOffset.FromUnixTimeMilliseconds(message.DateCreated).LocalDateTime;
        ToolTipService.SetToolTip(BubbleStack, stamp.ToString("f", CultureInfo.CurrentCulture));
    }

    private async Task LoadAvatarAsync(Message message)
    {
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(message.SenderAvatarPath!);
            using var stream = await file.OpenAsync(FileAccessMode.Read);
            var bitmap = new BitmapImage { DecodePixelWidth = 64 };
            await bitmap.SetSourceAsync(stream);
            if (_message?.PresentationKey == message.PresentationKey)
            {
                SenderAvatar.ProfilePicture = bitmap;
            }
        }
        catch { }
    }

    private static int TextElementCount(string text)
    {
        var enumerator = StringInfo.GetTextElementEnumerator(text);
        var count = 0;
        while (enumerator.MoveNext())
        {
            if (!string.IsNullOrWhiteSpace(enumerator.GetTextElement()))
            {
                count++;
            }
        }
        return count;
    }

    private static string SizeLabel(long bytes) => bytes switch
    {
        <= 0 => string.Empty,
        < 1024 => $"{bytes} B",
        < 1024 * 1024 => $"{bytes / 1024.0:0.#} KB",
        < 1024L * 1024 * 1024 => $"{bytes / (1024.0 * 1024):0.#} MB",
        _ => $"{bytes / (1024.0 * 1024 * 1024):0.##} GB",
    };

    private static string VoiceMessageLabel() => AppServices.Current.Localization.Language switch
    {
        "zh-Hans" => "语音消息",
        "zh-Hant" => "語音訊息",
        _ => "Voice message",
    };

    private static string SharedLocationLabel() => AppServices.Current.Localization.Language switch
    {
        "zh-Hans" => "共享位置",
        "zh-Hant" => "共享位置",
        _ => "Shared location",
    };

    private static string InteractiveMessageLabel() => AppServices.Current.Localization.Language switch
    {
        "zh-Hans" => "互动消息",
        "zh-Hant" => "互動訊息",
        _ => "Interactive message",
    };

    private static string HandwritingLabel() => AppServices.Current.Localization.Language switch
    {
        "zh-Hans" => "手写",
        "zh-Hant" => "手寫",
        _ => "Handwriting",
    };

    private static string NotDeliveredLabel() => AppServices.Current.Localization.Language switch
    {
        "zh-Hans" => "未送达 · 右键重试",
        "zh-Hant" => "未送達 · 右鍵重試",
        _ => "Not delivered · right-click to retry",
    };

    private static Brush ThemeBrush(string key) =>
        Application.Current.Resources.TryGetValue(key, out var value) && value is Brush brush
            ? brush
            : new SolidColorBrush(Microsoft.UI.Colors.Gray);

    private static string FooterLabel(Message message)
    {
        var language = AppServices.Current.Localization.Language;
        var labels = language switch
        {
            "zh-Hans" => new[] { "发送中", "已发送", "已送达", "已读", "发送失败" },
            "zh-Hant" => new[] { "傳送中", "已傳送", "已送達", "已讀", "傳送失敗" },
            _ => new[] { "Sending", "Sent", "Delivered", "Read", "Failed to send" },
        };
        var state = message.DeliveryState switch
        {
            MessageDeliveryState.Sending => labels[0],
            MessageDeliveryState.Sent => labels[1],
            MessageDeliveryState.Delivered => labels[2],
            MessageDeliveryState.Read => $"{labels[3]} · {message.SentAt}",
            MessageDeliveryState.Failed => labels[4],
            _ => message.SentAt,
        };
        if (message.IsEdited)
        {
            state += " · " + (language == "zh-Hans" ? "已编辑" : language == "zh-Hant" ? "已編輯" : "Edited");
        }
        return state;
    }
}

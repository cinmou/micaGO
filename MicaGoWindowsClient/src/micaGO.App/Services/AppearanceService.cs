using MicaGo.Infrastructure.Storage;
using Windows.UI;

namespace MicaGo.App.Services;

public sealed class AppearanceService(LocalCacheStore cache)
{
    private const string BackgroundKey = "appearance.chatBackground";
    private const string BubbleModeKey = "appearance.bubbleMode";
    private const string BubbleColorKey = "appearance.bubbleColor";
    private const string TwemojiFlagsKey = "appearance.twemojiFlags";
    private bool _initialized;

    public event EventHandler? AppearanceChanged;

    public string? ChatBackgroundPath { get; private set; }
    public bool BubbleFollowsSystem { get; private set; } = true;
    public Color BubbleColor { get; private set; } = Color.FromArgb(0xFF, 0x0A, 0x84, 0xFF);
    public bool TwemojiFlagsEnabled { get; private set; }

    /// <summary>W-UI8: bubble colour presets — the Flutter client's theme colours.</summary>
    public static IReadOnlyList<(string Key, Color Color)> BubbleColorPresets { get; } =
    [
        ("micago", Color.FromArgb(0xFF, 0x00, 0x7A, 0xFF)),
        ("bicao", Color.FromArgb(0xFF, 0x2E, 0x7D, 0x32)),
        ("wisteria", Color.FromArgb(0xFF, 0x7E, 0x6B, 0xAE)),
        ("citrus", Color.FromArgb(0xFF, 0xE6, 0x51, 0x00)),
        ("inkWash", Color.FromArgb(0xFF, 0x2E, 0x2E, 0x2E)),
        ("paleGold", Color.FromArgb(0xFF, 0xB8, 0x9B, 0x5E)),
        ("wineRed", Color.FromArgb(0xFF, 0x8B, 0x1E, 0x3F)),
        ("blueGreen", Color.FromArgb(0xFF, 0x1F, 0x6F, 0x6A)),
        ("indigo", Color.FromArgb(0xFF, 0x2F, 0x3A, 0x73)),
        ("peachBlossom", Color.FromArgb(0xFF, 0xE8, 0x89, 0xA8)),
        ("witheredGrass", Color.FromArgb(0xFF, 0x9C, 0x8A, 0x4F)),
        ("amber", Color.FromArgb(0xFF, 0xB8, 0x79, 0x2B)),
    ];

    public async Task InitializeAsync()
    {
        if (_initialized) return;
        await cache.InitializeAsync();
        ChatBackgroundPath = await cache.GetSettingAsync(BackgroundKey);
        BubbleFollowsSystem = !string.Equals(await cache.GetSettingAsync(BubbleModeKey), "custom", StringComparison.Ordinal);
        if (TryParseColor(await cache.GetSettingAsync(BubbleColorKey), out var color)) BubbleColor = color;
        // Windows ships no flag glyphs at all (regional indicators render as
        // bare letters), so the Twemoji flag fallback defaults to ON; the
        // toggle remains an opt-out.
        TwemojiFlagsEnabled = !string.Equals(await cache.GetSettingAsync(TwemojiFlagsKey), "false", StringComparison.Ordinal);
        _initialized = true;
    }

    public async Task SetChatBackgroundAsync(string sourcePath)
    {
        await InitializeAsync();
        var extension = Path.GetExtension(sourcePath).ToLowerInvariant();
        var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "micaGO", "appearance");
        Directory.CreateDirectory(directory);
        var destination = Path.Combine(directory, "chat-background" + extension);
        foreach (var oldFile in Directory.EnumerateFiles(directory, "chat-background.*"))
        {
            if (!string.Equals(oldFile, destination, StringComparison.OrdinalIgnoreCase)) File.Delete(oldFile);
        }
        if (!string.Equals(Path.GetFullPath(sourcePath), Path.GetFullPath(destination), StringComparison.OrdinalIgnoreCase)) File.Copy(sourcePath, destination, true);
        ChatBackgroundPath = destination;
        await cache.SetSettingAsync(BackgroundKey, destination);
        AppearanceChanged?.Invoke(this, EventArgs.Empty);
    }

    public async Task ClearChatBackgroundAsync()
    {
        await InitializeAsync();
        var oldPath = ChatBackgroundPath;
        ChatBackgroundPath = null;
        await cache.SetSettingAsync(BackgroundKey, string.Empty);
        if (!string.IsNullOrWhiteSpace(oldPath) && File.Exists(oldPath))
        {
            var appearanceDirectory = Path.GetFullPath(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "micaGO", "appearance"));
            var fullPath = Path.GetFullPath(oldPath);
            if (fullPath.StartsWith(appearanceDirectory + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) File.Delete(fullPath);
        }
        AppearanceChanged?.Invoke(this, EventArgs.Empty);
    }

    public async Task SetBubbleFollowsSystemAsync(bool followsSystem)
    {
        await InitializeAsync();
        BubbleFollowsSystem = followsSystem;
        await cache.SetSettingAsync(BubbleModeKey, followsSystem ? "system" : "custom");
        AppearanceChanged?.Invoke(this, EventArgs.Empty);
    }

    public async Task SetBubbleColorAsync(Color color)
    {
        await InitializeAsync();
        BubbleColor = Color.FromArgb(0xFF, color.R, color.G, color.B);
        await cache.SetSettingAsync(BubbleColorKey, $"#{BubbleColor.R:X2}{BubbleColor.G:X2}{BubbleColor.B:X2}");
        AppearanceChanged?.Invoke(this, EventArgs.Empty);
    }

    public async Task SetTwemojiFlagsEnabledAsync(bool enabled)
    {
        await InitializeAsync();
        TwemojiFlagsEnabled = enabled;
        await cache.SetSettingAsync(TwemojiFlagsKey, enabled ? "true" : "false");
        AppearanceChanged?.Invoke(this, EventArgs.Empty);
    }

    public static bool ShouldUseDarkText(Color color)
        => MicaGo.Core.Models.TextContrast.UseDarkText(color.R, color.G, color.B);

    private static bool TryParseColor(string? value, out Color color)
    {
        color = default;
        if (string.IsNullOrWhiteSpace(value)) return false;
        var text = value.Trim().TrimStart('#');
        if (text.Length != 6 || !uint.TryParse(text, System.Globalization.NumberStyles.HexNumber, null, out var raw)) return false;
        color = Color.FromArgb(0xFF, (byte)(raw >> 16), (byte)(raw >> 8), (byte)raw);
        return true;
    }
}

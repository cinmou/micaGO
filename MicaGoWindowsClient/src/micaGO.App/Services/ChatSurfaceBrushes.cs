using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace MicaGo.App.Services;

/// <summary>
/// Keep message cards and chips legible over a custom chat image. Header and
/// editor surfaces use system theme layers and stay outside the image canvas.
/// </summary>
public static class ChatSurfaceBrushes
{
    private static readonly (string Key, Color Light, Color Dark)[] SolidColors =
    [
        ("MicaGoChatChipBrush", Color.FromArgb(0xFF, 0xEC, 0xEC, 0xEC), Color.FromArgb(0xFF, 0x33, 0x33, 0x33)),
        ("MicaGoChatCardBrush", Color.FromArgb(0xFF, 0xFB, 0xFB, 0xFB), Color.FromArgb(0xFF, 0x2B, 0x2B, 0x2B)),
    ];

    private static readonly Dictionary<SolidColorBrush, Color> Originals = [];
    private static bool? _solid;

    public static void Apply(bool solid)
    {
        if (_solid == solid) return;
        _solid = solid;
        foreach (var merged in Application.Current.Resources.MergedDictionaries)
        {
            foreach (var (themeKey, value) in merged.ThemeDictionaries)
            {
                // HighContrast brushes are already opaque system colours.
                if (themeKey is not string name || value is not ResourceDictionary theme) continue;
                var dark = name is "Default" or "Dark";
                if (!dark && name != "Light") continue;

                foreach (var (key, light, darkColor) in SolidColors)
                {
                    if (!theme.TryGetValue(key, out var raw) || raw is not SolidColorBrush brush) continue;
                    if (!Originals.ContainsKey(brush)) Originals[brush] = brush.Color;
                    brush.Color = solid ? (dark ? darkColor : light) : Originals[brush];
                }
            }
        }
    }
}

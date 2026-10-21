namespace MicaGo.Core.Models;

/// <summary>Select the higher-contrast opaque text color using sRGB luminance.</summary>
public static class TextContrast
{
    public static bool UseDarkText(byte red, byte green, byte blue)
    {
        static double Linear(byte channel)
        {
            var value = channel / 255d;
            return value <= 0.04045 ? value / 12.92 : Math.Pow((value + 0.055) / 1.055, 2.4);
        }
        var luminance = 0.2126 * Linear(red) + 0.7152 * Linear(green) + 0.0722 * Linear(blue);
        return (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05);
    }
}

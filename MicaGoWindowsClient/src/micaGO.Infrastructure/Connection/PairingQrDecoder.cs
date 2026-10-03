using MicaGo.Core.Connection;
using ZXing;
using ZXing.Common;

namespace MicaGo.Infrastructure.Connection;

public static class PairingQrDecoder
{
    public static string? Decode(byte[] bgra, int width, int height)
    {
        if (width <= 0 || height <= 0 || width > 2048 || height > 2048 || bgra.Length != (long)width * height * 4) return null;
        var reader = new BarcodeReaderGeneric
        {
            AutoRotate = true,
            Options = new DecodingOptions { TryHarder = true, TryInverted = true, PossibleFormats = [BarcodeFormat.QR_CODE] },
        };
        var value = reader.Decode(bgra, width, height, RGBLuminanceSource.BitmapFormat.BGRA32)?.Text;
        if (string.IsNullOrWhiteSpace(value) || value.Length > 32768) return null;
        try { return PairingPayloadParser.Parse(value).Version >= 4 ? value : null; }
        catch (Exception error) when (error is PairingPayloadException or System.Text.Json.JsonException or InvalidOperationException) { return null; }
    }
}

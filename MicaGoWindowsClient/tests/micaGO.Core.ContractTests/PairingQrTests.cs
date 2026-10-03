using System.Text.Json;
using MicaGo.Infrastructure.Connection;
using ZXing;
using ZXing.Common;

internal static class PairingQrTests
{
    public static void Run()
    {
        var json = JsonSerializer.Serialize(new { version = 4, pairingCode = new string('a', 64), tlsFingerprint = new string('b', 64), candidates = new[] { new { kind = "lan", baseUrl = "https://192.168.1.3:3001", wsUrl = "wss://192.168.1.3:3001/ws" } } });
        AssertRead(json, json);
        AssertRead("https://example.com", null);
        AssertRead("{\"version\":\"bad\"}", null);
        var pixels = new byte[32 * 32 * 4];
        if (PairingQrDecoder.Decode(pixels, 32, 32) is not null || PairingQrDecoder.Decode(pixels, 100, 100) is not null) throw new Exception("Blank or malformed image accepted.");
    }
    private static void AssertRead(string content, string? expected)
    {
        var writer = new BarcodeWriterPixelData { Format = BarcodeFormat.QR_CODE, Options = new EncodingOptions { Width = 720, Height = 720, Margin = 4 } };
        var image = writer.Write(content);
        if (PairingQrDecoder.Decode(image.Pixels, image.Width, image.Height) != expected) throw new Exception("Pairing QR recognition or validation failed.");
    }
}

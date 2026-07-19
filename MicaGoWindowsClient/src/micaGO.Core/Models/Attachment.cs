namespace MicaGo.Core.Models;

public sealed record Attachment(
    string Id,
    string FileName,
    string MimeType,
    long Size,
    string? Kind = null,
    string? PreviewUrl = null,
    bool IsSticker = false,
    int Width = 0,
    int Height = 0,
    string? OriginalMimeType = null,
    string? Uti = null,
    bool IsVoiceMessage = false,
    string? DisplayKind = null,
    bool NeedsPreviewConversion = false)
{
    public bool IsStickerLike => IsSticker || string.Equals(Kind, "sticker", StringComparison.OrdinalIgnoreCase);
    public bool IsImage => IsStickerLike || MimeType.StartsWith("image/", StringComparison.OrdinalIgnoreCase) || ImageExtensions.Contains(Path.GetExtension(FileName));
    public bool IsVideo => string.Equals(Kind, "video", StringComparison.OrdinalIgnoreCase) || MimeType.StartsWith("video/", StringComparison.OrdinalIgnoreCase) || VideoExtensions.Contains(Path.GetExtension(FileName));
    public bool IsAudio => string.Equals(Kind, "audio", StringComparison.OrdinalIgnoreCase) || MimeType.StartsWith("audio/", StringComparison.OrdinalIgnoreCase) || AudioExtensions.Contains(Path.GetExtension(FileName));
    public bool IsLocation => string.Equals(Kind, "location", StringComparison.OrdinalIgnoreCase) || string.Equals(MimeType, "text/x-vlocation", StringComparison.OrdinalIgnoreCase);
    public bool IsLinkPreview => string.IsNullOrWhiteSpace(MimeType) && (FileName.StartsWith("http://",StringComparison.OrdinalIgnoreCase)||FileName.StartsWith("https://",StringComparison.OrdinalIgnoreCase));
    private static readonly HashSet<string> ImageExtensions = new(StringComparer.OrdinalIgnoreCase) { ".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif", ".tif", ".tiff" };
    private static readonly HashSet<string> VideoExtensions = new(StringComparer.OrdinalIgnoreCase) { ".mov", ".mp4", ".m4v", ".avi", ".webm" };
    private static readonly HashSet<string> AudioExtensions = new(StringComparer.OrdinalIgnoreCase) { ".m4a", ".caf", ".mp3", ".wav", ".aac", ".ogg" };
}

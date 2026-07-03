package store

import (
	"mime"
	"path/filepath"
	"strings"
)

// Attachment kind values returned in AttachmentJSON.AttachmentKind. These are a
// small, stable, additive classification derived from the MIME type, Apple UTI,
// the is_sticker flag, and the file extension. They are advisory only: clients
// that need precision should still inspect mimeType/uti.
const (
	AttachmentKindImage    = "image"
	AttachmentKindVideo    = "video"
	AttachmentKindAudio    = "audio"
	AttachmentKindFile     = "file"
	AttachmentKindSticker  = "sticker"
	AttachmentKindLocation = "location" // C37: iMessage shared-location (vlocation)
	AttachmentKindUnknown  = "unknown"

	DisplayKindImage             = "image"
	DisplayKindImageNeedsPreview = "image_needs_preview"
	DisplayKindVideo             = "video"
	DisplayKindAudio             = "audio"
	DisplayKindVoice             = "voice"
	DisplayKindFile              = "file"
	DisplayKindSticker           = "sticker"
	DisplayKindLocation          = "location"
	DisplayKindUnknown           = "unknown"
)

// utiMimeOverrides maps Apple UTIs that Go's mime package can't resolve (or that
// have an Apple-specific container) to a sensible MIME type. Kept intentionally
// small and read-only.
var utiMimeOverrides = map[string]string{
	"public.jpeg":                  "image/jpeg",
	"public.png":                   "image/png",
	"public.heic":                  "image/heic",
	"public.heif":                  "image/heif",
	"public.tiff":                  "image/tiff",
	"com.compuserve.gif":           "image/gif",
	"public.mpeg-4":                "video/mp4",
	"com.apple.quicktime-movie":    "video/quicktime",
	"public.mpeg":                  "video/mpeg",
	"public.mp3":                   "audio/mp3",
	"public.aac-audio":             "audio/aac",
	"com.apple.m4a-audio":          "audio/m4a",
	"com.apple.coreaudio-format":   "audio/x-caf",
	"com.adobe.pdf":                "application/pdf",
	"public.vcard":                 "text/vcard",
	"com.apple.coreaudio.caf":      "audio/x-caf",
	"com.microsoft.waveform-audio": "audio/wav",
}

// extMimeOverrides gives deterministic MIME types for common attachment
// extensions, independent of the host's (possibly empty) MIME database. Checked
// before mime.TypeByExtension.
var extMimeOverrides = map[string]string{
	".jpg":  "image/jpeg",
	".jpeg": "image/jpeg",
	".png":  "image/png",
	".gif":  "image/gif",
	".heic": "image/heic",
	".heif": "image/heif",
	".tiff": "image/tiff",
	".tif":  "image/tiff",
	".webp": "image/webp",
	".bmp":  "image/bmp",
	".mov":  "video/quicktime",
	".mp4":  "video/mp4",
	".m4v":  "video/mp4",
	".3gp":  "video/3gpp",
	".avi":  "video/x-msvideo",
	".mp3":  "audio/mpeg",
	".m4a":  "audio/mp4",
	".aac":  "audio/aac",
	".wav":  "audio/wav",
	".aiff": "audio/aiff",
	".caf":  "audio/x-caf",
	".pdf":  "application/pdf",
	".txt":  "text/plain",
	".vcf":  "text/vcard",
	".zip":  "application/zip",
}

// voiceMessageUTIs / voiceMessageMIMEs identify the canonical iMessage voice
// memo container (CAF). A standalone .mp3/.m4a a user attaches is treated as a
// regular audio file, not a "voice message".
var voiceMessageUTIs = map[string]struct{}{
	"com.apple.coreaudio-format": {},
	"com.apple.coreaudio.caf":    {},
}

// InferMimeType returns the best-known MIME type for an attachment. The stored
// MIME (from chat.db) is authoritative and returned unchanged when present.
// Otherwise it falls back to the UTI, then the file extension of transferName
// or filename. Returns nil only when nothing can be inferred.
func InferMimeType(mimeType, uti, transferName, filename *string) *string {
	if v := strings.TrimSpace(deref(mimeType)); v != "" {
		return mimeType
	}

	if u := strings.TrimSpace(deref(uti)); u != "" {
		if m, ok := utiMimeOverrides[u]; ok {
			return strPtr(m)
		}
	}

	for _, name := range []string{deref(transferName), deref(filename)} {
		if m := mimeFromExtension(name); m != "" {
			return strPtr(m)
		}
	}

	return nil
}

// IsLocationAttachment reports an iMessage shared-location row. Apple stores the
// "Share My Location"/"Send My Current Location" payload as a small vlocation
// file (a .loc.vcf carrying an Apple Maps URL). Detected by MIME/UTI/extension.
func IsLocationAttachment(mimeType, uti, transferName, filename *string) bool {
	m := strings.ToLower(strings.TrimSpace(deref(mimeType)))
	if m == "text/x-vlocation" || m == "text/vlocation" {
		return true
	}
	u := strings.ToLower(strings.TrimSpace(deref(uti)))
	if u == "public.vlocation" || u == "com.apple.mapkit.map-item" {
		return true
	}
	for _, name := range []string{deref(transferName), deref(filename)} {
		l := strings.ToLower(strings.TrimSpace(name))
		if strings.HasSuffix(l, ".loc.vcf") || strings.HasSuffix(l, ".vlocation") {
			return true
		}
	}
	return false
}

// isStickerUTI catches stickers whose chat.db is_sticker flag is missing/0 — e.g.
// some third-party sticker packs — by their UTI. Apple sticker payloads carry a
// sticker UTI even when the flag isn't set.
func isStickerUTI(uti *string) bool {
	u := strings.ToLower(strings.TrimSpace(deref(uti)))
	if u == "" {
		return false
	}
	return u == "com.apple.sticker" ||
		strings.HasPrefix(u, "com.apple.sticker") ||
		strings.HasSuffix(u, ".sticker") ||
		strings.Contains(u, ".sticker.")
}

// AttachmentKind classifies an attachment into a coarse, stable bucket.
func AttachmentKind(isSticker bool, mimeType, uti, transferName, filename *string) string {
	// C37: location BEFORE the generic file fallback — a vlocation has a text MIME
	// that would otherwise classify as "file".
	if IsLocationAttachment(mimeType, uti, transferName, filename) {
		return AttachmentKindLocation
	}
	if isSticker || isStickerUTI(uti) {
		return AttachmentKindSticker
	}

	effective := strings.ToLower(strings.TrimSpace(deref(mimeType)))
	if effective == "" {
		if m := InferMimeType(nil, uti, transferName, filename); m != nil {
			effective = strings.ToLower(strings.TrimSpace(*m))
		}
	}

	switch {
	case strings.HasPrefix(effective, "image/"):
		return AttachmentKindImage
	case strings.HasPrefix(effective, "video/"):
		return AttachmentKindVideo
	case strings.HasPrefix(effective, "audio/"):
		return AttachmentKindAudio
	}

	// UTI-based fallback when MIME was unhelpful.
	u := strings.ToLower(strings.TrimSpace(deref(uti)))
	switch {
	case strings.HasPrefix(u, "public.image") || u == "public.jpeg" || u == "public.png" || u == "public.heic" || u == "public.heif" || u == "public.tiff" || u == "com.compuserve.gif":
		return AttachmentKindImage
	case strings.HasPrefix(u, "public.movie") || strings.HasPrefix(u, "public.video") || u == "com.apple.quicktime-movie" || u == "public.mpeg-4" || u == "public.mpeg":
		return AttachmentKindVideo
	case strings.HasPrefix(u, "public.audio") || u == "com.apple.coreaudio-format" || u == "com.apple.coreaudio.caf" || u == "public.mp3" || u == "public.aac-audio" || u == "com.apple.m4a-audio":
		return AttachmentKindAudio
	}

	// We have a typed identity but it's not media: file. A bare filename or an
	// unknown/generic UTI with no MIME/known extension is intentionally left
	// unknown. Apple URLBalloon/link-preview payloads often look like UUID files
	// (sometimes public.data) with no useful type, and BlueBubbles keeps those
	// out of realAttachments.
	if effective != "" {
		return AttachmentKindFile
	}

	return AttachmentKindUnknown
}

// IsVoiceMessage reports whether the attachment is an iMessage voice memo.
// CAF is Apple's canonical container; MicaGo-recorded voice notes are sent as
// voice_*.m4a because Flutter/Android cannot produce CAF without a native
// encoder. Those are still user-created voice messages, not arbitrary music.
func IsVoiceMessage(uti, mimeType *string, names ...*string) bool {
	if u := strings.TrimSpace(deref(uti)); u != "" {
		if _, ok := voiceMessageUTIs[u]; ok {
			return true
		}
	}
	if m := strings.ToLower(strings.TrimSpace(deref(mimeType))); m == "audio/x-caf" || m == "audio/caf" {
		return true
	}
	for _, namePtr := range names {
		name := strings.ToLower(strings.TrimSpace(filepath.Base(deref(namePtr))))
		if strings.HasPrefix(name, "voice_") && (strings.HasSuffix(name, ".m4a") || strings.HasSuffix(name, ".aac")) {
			return true
		}
	}
	return false
}

func IsTIFFAttachment(mimeType, uti, transferName, filename *string) bool {
	m := strings.ToLower(strings.TrimSpace(deref(mimeType)))
	if m == "image/tiff" || m == "image/tif" || m == "image/x-tiff" {
		return true
	}
	u := strings.ToLower(strings.TrimSpace(deref(uti)))
	if u == "public.tiff" {
		return true
	}
	for _, name := range []string{deref(transferName), deref(filename)} {
		ext := strings.ToLower(filepath.Ext(name))
		if ext == ".tif" || ext == ".tiff" {
			return true
		}
	}
	return false
}

func NeedsPreviewConversion(isSticker bool, mimeType, uti, transferName, filename *string) bool {
	// C39: stickers are NOT force-converted any more. A sticker is usually a plain
	// PNG (in ~/Library/Messages/StickerCache) the client can render directly, so
	// `isSticker` is intentionally unused now.
	// C48: HEIC/HEIF/TIFF AND JPEG are routed through the server preview. HEIC/TIFF
	// because the Flutter/Skia client can't decode them; JPEG because iPhone photos
	// bake their rotation into EXIF orientation and the client was still showing
	// some sideways — the Quick Look preview bakes the orientation into the pixels
	// so every device agrees. PNG stays direct (web-renderable, no EXIF orientation).
	_ = isSticker
	if IsTIFFAttachment(mimeType, uti, transferName, filename) {
		return true
	}
	m := strings.ToLower(strings.TrimSpace(deref(mimeType)))
	if m == "image/jpeg" || m == "image/jpg" ||
		m == "image/heic" || m == "image/heif" ||
		m == "image/heic-sequence" || m == "image/heif-sequence" {
		return true
	}
	u := strings.ToLower(strings.TrimSpace(deref(uti)))
	if u == "public.jpeg" || u == "public.heic" || u == "public.heif" ||
		u == "public.heic-sequence" || u == "public.heif-sequence" {
		return true
	}
	for _, name := range []string{deref(transferName), deref(filename)} {
		ext := strings.ToLower(filepath.Ext(name))
		if ext == ".jpg" || ext == ".jpeg" ||
			ext == ".heic" || ext == ".heif" || ext == ".heics" {
			return true
		}
	}
	return false
}

func IsPreviewableImage(kind string, mimeType, uti, transferName, filename *string) bool {
	if kind != AttachmentKindImage {
		return false
	}
	return !NeedsPreviewConversion(false, mimeType, uti, transferName, filename)
}

// IsVideoAttachment reports whether an attachment is a video, so the server can
// serve a Quick Look poster frame as its preview thumbnail (C53).
func IsVideoAttachment(mimeType, uti, transferName, filename *string) bool {
	return AttachmentKind(false, mimeType, uti, transferName, filename) == AttachmentKindVideo
}

func DisplayKind(kind string, isVoice bool, needsPreviewConversion bool) string {
	if isVoice {
		return DisplayKindVoice
	}
	switch kind {
	case AttachmentKindLocation:
		return DisplayKindLocation
	case AttachmentKindSticker:
		return DisplayKindSticker
	case AttachmentKindImage:
		if needsPreviewConversion {
			return DisplayKindImageNeedsPreview
		}
		return DisplayKindImage
	case AttachmentKindVideo:
		return DisplayKindVideo
	case AttachmentKindAudio:
		return DisplayKindAudio
	case AttachmentKindFile:
		return DisplayKindFile
	default:
		return DisplayKindUnknown
	}
}

// IsAttachmentPreviewPayload reports attachment rows that belong to Apple's
// rich-link/interactive payload rather than a user-visible file. BlueBubbles'
// equivalent boundary is realAttachments (mimeType != nil) vs previewAttachments
// (mimeType == nil). We keep the rule conservative: typed media/files and
// stickers still render, while untyped opaque rows do not become blank cards.
func IsAttachmentPreviewPayload(a AttachmentJSON) bool {
	if a.IsSticker {
		return false
	}
	return a.AttachmentKind == AttachmentKindUnknown && a.MimeType == nil
}

// DecorateAttachmentJSON fills the additive, derived fields on an AttachmentJSON
// from its already-populated raw fields (MimeType, Uti, TransferName, Filename,
// IsSticker). The stored MimeType is preserved when present and only filled in
// when it was empty, so no raw data is lost.
func DecorateAttachmentJSON(a *AttachmentJSON) {
	if a == nil {
		return
	}
	if a.OriginalMimeType == nil {
		a.OriginalMimeType = a.MimeType
	}
	a.MimeType = InferMimeType(a.MimeType, a.Uti, a.TransferName, a.Filename)
	a.AttachmentKind = AttachmentKind(a.IsSticker, a.MimeType, a.Uti, a.TransferName, a.Filename)
	a.IsVoiceMessage = IsVoiceMessage(a.Uti, a.MimeType, a.TransferName, a.Filename)
	a.NeedsPreviewConversion = NeedsPreviewConversion(a.IsSticker, a.MimeType, a.Uti, a.TransferName, a.Filename)
	a.IsPreviewableImage = IsPreviewableImage(a.AttachmentKind, a.MimeType, a.Uti, a.TransferName, a.Filename)
	a.DisplayKind = DisplayKind(a.AttachmentKind, a.IsVoiceMessage, a.NeedsPreviewConversion)
}

func mimeFromExtension(name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		return ""
	}
	ext := strings.ToLower(filepath.Ext(name))
	if ext == "" {
		return ""
	}
	if m, ok := extMimeOverrides[ext]; ok {
		return m
	}
	m := mime.TypeByExtension(ext)
	if m == "" {
		return ""
	}
	// Strip any "; charset=..." parameter for a clean type.
	if idx := strings.IndexByte(m, ';'); idx >= 0 {
		m = strings.TrimSpace(m[:idx])
	}
	return m
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func strPtr(s string) *string {
	return &s
}

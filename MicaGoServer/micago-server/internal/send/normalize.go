package send

import (
	"strings"
	"unicode"
)

func NormalizeText(value string) string {
	var b strings.Builder
	for _, r := range strings.TrimSpace(value) {
		if unicode.IsSpace(r) || unicode.IsControl(r) {
			continue
		}
		// Ignore emoji/text presentation variation selectors and BOM so
		// platform differences (e.g. "❤️" vs "❤") still confirm against chat.db.
		if r == '\uFE0E' || r == '\uFE0F' || r == '\uFEFF' {
			continue
		}
		b.WriteRune(unicode.ToLower(r))
	}
	return b.String()
}

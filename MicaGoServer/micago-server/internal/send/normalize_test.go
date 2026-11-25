package send

import "testing"

func TestNormalizeText(t *testing.T) {
	got := NormalizeText("  HeLLo \n 世界  ")
	if got != "hello世界" {
		t.Fatalf("expected normalized text hello世界, got %q", got)
	}
}

func TestNormalizeTextIgnoresEmojiVariationSelectors(t *testing.T) {
	withVS := NormalizeText("❤️ ✌️ 1️⃣")
	withoutVS := NormalizeText("\u2764 \u270c 1\u20e3")
	if withVS != withoutVS {
		t.Fatalf("expected emoji variation selectors to normalize equally: %q vs %q", withVS, withoutVS)
	}
}

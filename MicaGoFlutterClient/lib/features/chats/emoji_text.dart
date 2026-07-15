// ignore_for_file: valid_regexps

/// C24: lightweight emoji-only detection, adapted from BlueBubbles'
/// `shouldShowBigEmoji` (`helpers/types/helpers/message_helper.dart`). An
/// emoji-only message (no other visible text) with a small number of emoji is
/// rendered larger and cleaner; mixed text+emoji stays a normal text bubble.
/// Pure + unit-testable; intentionally not a full grapheme parser.
library;

// Extended_Pictographic covers the vast majority of emoji. Country flags are
// different: they are made from two regional indicator code points, so handle
// those pairs explicitly before stripping the remaining emoji "glue".
final RegExp _regionalIndicatorPair = RegExp(
  r'[\u{1F1E6}-\u{1F1FF}]{2}',
  unicode: true,
);

// Strip the emoji "glue" code points (skin-tone modifiers, regional indicators,
// ZWJ U+200D, variation selector U+FE0F, keycap U+20E3) so multi-codepoint emoji
// do not leave visible text behind during emoji-only detection.
final RegExp _emojiGlue = RegExp(
  r'[\u{1F1E6}-\u{1F1FF}\u{1F3FB}-\u{1F3FF}\u200D\uFE0F\u{20E3}]',
  unicode: true,
);
// The analyzer's static regex check doesn't understand Unicode property escapes,
// but Dart's runtime does (covered by emoji_text_test.dart).
final RegExp _pictographic = RegExp(
  r'\p{Extended_Pictographic}',
  unicode: true,
);

/// True when [text] is only emoji (plus whitespace) — no other visible text.
bool isEmojiOnly(String text) {
  final t = text.trim();
  if (t.isEmpty) return false;
  if (_pictographic.firstMatch(t) == null &&
      _regionalIndicatorPair.firstMatch(t) == null) {
    return false;
  }
  final stripped = t
      .replaceAll(_regionalIndicatorPair, '')
      .replaceAll(_pictographic, '')
      .replaceAll(_emojiGlue, '')
      .replaceAll(RegExp(r'\s+'), '');
  return stripped.isEmpty;
}

/// Number of emoji in [text] (a rough cluster count).
int emojiCount(String text) {
  final withoutFlags = text.replaceAll(_regionalIndicatorPair, '');
  return _regionalIndicatorPair.allMatches(text).length +
      _pictographic.allMatches(withoutFlags).length;
}

/// BlueBubbles-style "big emoji": emoji-only with at most 3 emoji. These render
/// at [bigEmojiFontSize]; everything else renders as a normal text bubble.
bool isBigEmoji(String text) {
  if (!isEmojiOnly(text)) return false;
  final n = emojiCount(text);
  return n >= 1 && n <= 3;
}

/// Font size for a big-emoji message (≈3× a normal body line, like BB's 3.0
/// scale factor), nudged down a little as the count grows so 3 emoji still fit.
double bigEmojiFontSize(String text) {
  switch (emojiCount(text)) {
    case 1:
      return 96;
    case 2:
      return 72;
    default:
      return 58;
  }
}

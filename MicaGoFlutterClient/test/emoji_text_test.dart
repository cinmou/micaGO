import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/features/chats/emoji_text.dart';

void main() {
  group('C24 emoji-only detection', () {
    test('single / few emoji are emoji-only and big', () {
      expect(isEmojiOnly('😀'), isTrue);
      expect(isBigEmoji('😀'), isTrue);
      expect(isEmojiOnly('😀😂🥰'), isTrue);
      expect(isBigEmoji('😀😂🥰'), isTrue);
      expect(bigEmojiFontSize('😀'), greaterThan(bigEmojiFontSize('😀😂🥰')));
    });

    test('country flag emoji are emoji-only and big', () {
      expect(isEmojiOnly('🇬🇧'), isTrue);
      expect(isBigEmoji('🇬🇧'), isTrue);
      expect(emojiCount('🇬🇧'), 1);
      expect(isEmojiOnly('🇬🇧🇺🇸🇯🇵'), isTrue);
      expect(isBigEmoji('🇬🇧🇺🇸🇯🇵'), isTrue);
      expect(emojiCount('🇬🇧🇺🇸🇯🇵'), 3);
    });

    test('emoji with surrounding whitespace still counts as emoji-only', () {
      expect(isEmojiOnly('  😀  '), isTrue);
    });

    test('mixed text + emoji is NOT emoji-only', () {
      expect(isEmojiOnly('hi 😀'), isFalse);
      expect(isBigEmoji('great 👍'), isFalse);
      expect(isEmojiOnly('😀 lol'), isFalse);
      expect(isEmojiOnly('flag 🇬🇧'), isFalse);
    });

    test('plain text is not emoji', () {
      expect(isEmojiOnly('hello'), isFalse);
      expect(isBigEmoji('hello'), isFalse);
      expect(isEmojiOnly(''), isFalse);
    });

    test('many emoji are emoji-only but not "big"', () {
      expect(isEmojiOnly('😀😂🥰😎🔥'), isTrue);
      expect(isBigEmoji('😀😂🥰😎🔥'), isFalse); // > 3 → normal size
    });
  });
}

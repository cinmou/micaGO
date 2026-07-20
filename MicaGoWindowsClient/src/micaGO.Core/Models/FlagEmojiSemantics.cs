using System.Globalization;
using System.Text;

namespace MicaGo.Core.Models;

public sealed record FlagEmojiSegment(string Text, string? AssetKey, bool IsEmoji17 = false)
{
    public bool IsFlag => AssetKey is not null && !IsEmoji17;
    public bool HasAsset => AssetKey is not null;
}

/// <summary>
/// Splits text on Unicode grapheme boundaries and identifies only flag emoji.
/// Every other emoji remains text so Windows continues to render it natively.
/// </summary>
public static class FlagEmojiSemantics
{
    public static IReadOnlyList<FlagEmojiSegment> Split(string text, bool includeFlags = true, bool includeEmoji17 = false)
    {
        if (string.IsNullOrEmpty(text)) return [];
        var result = new List<FlagEmojiSegment>();
        var plain = new StringBuilder();
        var elements = StringInfo.GetTextElementEnumerator(text);
        while (elements.MoveNext())
        {
            var element = elements.GetTextElement();
            var asset = includeFlags ? AssetKey(element) : null;
            var isEmoji17 = false;
            if (asset is null && includeEmoji17)
            {
                asset = Emoji17AssetKey(element);
                isEmoji17 = asset is not null;
            }
            if (asset is null)
            {
                plain.Append(element);
                continue;
            }

            if (plain.Length > 0)
            {
                result.Add(new FlagEmojiSegment(plain.ToString(), null));
                plain.Clear();
            }
            result.Add(new FlagEmojiSegment(element, asset, isEmoji17));
        }

        if (plain.Length > 0) result.Add(new FlagEmojiSegment(plain.ToString(), null));
        return result;
    }

    public static string? AssetKey(string element)
    {
        var runes = element.EnumerateRunes().Select(rune => rune.Value).ToArray();
        if (runes.Length == 2 && runes.All(value => value is >= 0x1F1E6 and <= 0x1F1FF))
            return Key(runes);

        var withoutVariation = runes.Where(value => value != 0xFE0F).ToArray();
        var normalized = Key(withoutVariation);
        return normalized switch
        {
            "1f38c" => "1f38c", // crossed flags
            "1f3c1" => "1f3c1", // chequered flag
            "1f3f3" => "1f3f3", // white flag
            "1f3f4" => "1f3f4", // black flag
            "1f6a9" => "1f6a9", // triangular flag
            "1f3f3-200d-1f308" => "1f3f3-fe0f-200d-1f308", // rainbow
            "1f3f3-200d-26a7" => "1f3f3-fe0f-200d-26a7-fe0f", // transgender
            "1f3f4-200d-2620" => "1f3f4-200d-2620-fe0f", // pirate / skull flag
            _ when IsSubdivisionFlag(withoutVariation) => Key(withoutVariation),
            _ => null,
        };
    }

    public static string? Emoji17AssetKey(string element)
    {
        var runes = element.EnumerateRunes().Select(rune => rune.Value).ToArray();
        if (runes.Length == 0) return null;
        var containsNewCharacter = runes.Any(value => value is 0x1FAEA or 0x1FAEF or 0x1FAC8 or 0x1FA70 or 0x1FACD or 0x1F6D8 or 0x1FA8A or 0x1FA8E);
        var hasSkinTone = runes.Any(value => value is >= 0x1F3FB and <= 0x1F3FF);
        var isExpandedPair = hasSkinTone && (runes[0] is 0x1F46F or 0x1F93C);
        var isNewBunnyPair = runes.Contains(0x1F430) && runes.Count(value => value is >= 0x1F3FB and <= 0x1F3FF) >= 2;
        return containsNewCharacter || isExpandedPair || isNewBunnyPair ? Key(runes) : null;
    }

    private static bool IsSubdivisionFlag(int[] runes) =>
        runes.Length >= 4 && runes[0] == 0x1F3F4 && runes[^1] == 0xE007F &&
        runes[1..^1].All(value => value is >= 0xE0020 and <= 0xE007E);

    private static string Key(IEnumerable<int> runes) =>
        string.Join('-', runes.Select(value => value.ToString("x", CultureInfo.InvariantCulture)));
}

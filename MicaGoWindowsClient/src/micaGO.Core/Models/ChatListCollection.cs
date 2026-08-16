using System.Collections.ObjectModel;

namespace MicaGo.Core.Models;

public readonly record struct ChatRowMove(string ListKey, int OldIndex, int NewIndex);

public sealed class ChatListMutationEventArgs(
    IReadOnlyList<ChatRowMove> moves,
    int inserted,
    int removed,
    bool animate) : EventArgs
{
    public IReadOnlyList<ChatRowMove> Moves { get; } = moves;
    public int Inserted { get; } = inserted;
    public int Removed { get; } = removed;
    public bool Animate { get; } = animate;
}

/// <summary>
/// Applies a keyed snapshot using only the minimum Move/Insert/Remove events.
/// It never raises Reset or Replace, so a ListView can retain realized rows.
/// </summary>
public sealed class ChatListCollection : ObservableCollection<ChatSummary>
{
    public event EventHandler<ChatListMutationEventArgs>? Mutated;

    public void Apply(IReadOnlyList<ChatSummary> target, bool animateMoves)
    {
        var moves = new List<ChatRowMove>();
        var inserted = 0;
        var removed = 0;
        var keys = new HashSet<string>(target.Select(chat => chat.ListKey), StringComparer.OrdinalIgnoreCase);

        for (var index = Count - 1; index >= 0; index--)
        {
            if (keys.Contains(this[index].ListKey)) continue;
            RemoveAt(index);
            removed++;
        }

        for (var targetIndex = 0; targetIndex < target.Count; targetIndex++)
        {
            var desired = target[targetIndex];
            if (targetIndex < Count && KeyEquals(this[targetIndex], desired)) continue;

            var oldIndex = IndexOfKey(desired.ListKey, targetIndex + 1);
            if (oldIndex >= 0)
            {
                Move(oldIndex, targetIndex);
                moves.Add(new ChatRowMove(desired.ListKey, oldIndex, targetIndex));
            }
            else
            {
                Insert(targetIndex, desired);
                inserted++;
            }
        }

        while (Count > target.Count)
        {
            RemoveAt(Count - 1);
            removed++;
        }

        if (moves.Count > 0 || inserted > 0 || removed > 0)
            Mutated?.Invoke(this, new ChatListMutationEventArgs(moves, inserted, removed, animateMoves));
    }

    private int IndexOfKey(string key, int start)
    {
        for (var index = Math.Max(0, start); index < Count; index++)
            if (string.Equals(this[index].ListKey, key, StringComparison.OrdinalIgnoreCase)) return index;
        return -1;
    }

    private static bool KeyEquals(ChatSummary left, ChatSummary right) =>
        string.Equals(left.ListKey, right.ListKey, StringComparison.OrdinalIgnoreCase);
}

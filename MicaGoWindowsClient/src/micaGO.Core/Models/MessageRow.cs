using System.ComponentModel;

namespace MicaGo.Core.Models;

public enum MessageEntranceKind
{
    None,
    LocalSend,
    Realtime,
}

/// <summary>
/// Stable UI identity for one presented timeline row. The contained immutable
/// message may change as delivery/grouping metadata is reconciled, while the
/// ListView item and its recycled container remain the same.
/// </summary>
public sealed class MessageRow : INotifyPropertyChanged
{
    private Message _value;
    private MessageEntranceKind _pendingEntrance;

    public MessageRow(Message value,MessageEntranceKind entrance=MessageEntranceKind.None)
    {
        _value=value;
        _pendingEntrance=entrance;
    }

    public Message Value => _value;
    public string PresentationKey => _value.PresentationKey;

    public event PropertyChangedEventHandler? PropertyChanged;

    public bool Update(Message value)
    {
        if (_value.Equals(value)) return false;
        _value = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Value)));
        return true;
    }

    public bool TryConsumeEntrance(out MessageEntranceKind entrance)
    {
        entrance=_pendingEntrance;
        _pendingEntrance=MessageEntranceKind.None;
        return entrance!=MessageEntranceKind.None;
    }
}

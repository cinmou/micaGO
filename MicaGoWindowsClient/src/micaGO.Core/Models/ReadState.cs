namespace MicaGo.Core.Models;
public sealed record ReadPosition(string ChatGuid, long ReadThrough, bool? MarkedUnread = null, long UnreadRevision = 0, long? BaseUnreadRevision = null);
public sealed record ReadState(string ServerId, long Revision, IReadOnlyList<ReadPosition> Data);
public sealed record ReadStateMutation(string ServerId, IReadOnlyList<ReadPosition> Changes);

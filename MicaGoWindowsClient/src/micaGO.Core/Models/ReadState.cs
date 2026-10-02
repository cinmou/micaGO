namespace MicaGo.Core.Models;
public sealed record ReadPosition(string ChatGuid, long ReadThrough);
public sealed record ReadState(string ServerId, long Revision, IReadOnlyList<ReadPosition> Data);
public sealed record ReadStateMutation(string ServerId, IReadOnlyList<ReadPosition> Changes);

namespace MicaGo.Core.Models;

public sealed record MessagePreference(string MessageKey, bool Hidden, long Revision);
public sealed record MessagePreferences(string ServerId, long Revision, IReadOnlyList<MessagePreference> Data);
public sealed record MessagePreferenceChange(string MessageKey, bool Hidden, long BaseRevision);
public sealed record MessagePreferenceMutation(string ServerId, string MutationId, IReadOnlyList<MessagePreferenceChange> Changes);

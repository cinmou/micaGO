namespace MicaGo.Core.Models;

public sealed record ServerSyncSettings(
    string BackfillMode,
    int RecentMessagesPerChat,
    bool IncludeIMessage,
    bool IncludeSMS,
    bool IncludeRCS,
    bool IncludeUnknown,
    bool IncludeDebugInNormal,
    bool AllowSmsSend);

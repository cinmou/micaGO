namespace MicaGo.Core.Models;

public sealed record DeviceRegistration(
    string Id,
    string Name,
    string AppVersion,
    string Platform,
    string Mode,
    string ClientType,
    string PushProvider,
    bool PushEnabled,
    bool Background);

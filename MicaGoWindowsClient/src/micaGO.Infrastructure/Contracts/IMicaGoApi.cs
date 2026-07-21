using MicaGo.Core.Models;

namespace MicaGo.Infrastructure.Contracts;

public interface IMicaGoApi : IDisposable
{
    string BaseUrl { get; }
    Task<IReadOnlyList<ChatSummary>> GetChatsAsync(CancellationToken cancellationToken = default);
    Task<IReadOnlyList<Message>> GetMessagesAsync(string chatId, int limit = 50, int offset = 0, CancellationToken cancellationToken = default);
    Task<MessageDelta> GetMessagesDeltaAsync(long? since, int limit = 200, CancellationToken cancellationToken = default);
    Task<Message> SendTextAsync(string chatId, string text, string? tempId = null, CancellationToken cancellationToken = default);
    Task<AttachmentUploadResult> SendAttachmentAsync(string chatId, string tempId, string filePath, bool isAudioMessage = false, IProgress<double>? progress = null, CancellationToken cancellationToken = default);
    Task<byte[]> GetAttachmentBytesAsync(string attachmentId, bool preview = false, bool playable = false, CancellationToken cancellationToken = default);
    Task<MessageActionCapabilities> GetMessageActionCapabilitiesAsync(CancellationToken cancellationToken = default);
    Task EditMessageAsync(string chatId, string messageId, string text, int partIndex = 0, CancellationToken cancellationToken = default);
    Task RetractMessageAsync(string chatId, string messageId, int partIndex = 0, CancellationToken cancellationToken = default);
    Task DeleteMessageAsync(string chatId, string messageId, CancellationToken cancellationToken = default);
    Task<bool> GetTestContactEnabledAsync(CancellationToken cancellationToken = default);
    Task SetTestContactEnabledAsync(bool enabled, CancellationToken cancellationToken = default);
    Task<string> RegisterDeviceAsync(DeviceRegistration registration, CancellationToken cancellationToken = default);
    Task HeartbeatDeviceAsync(string deviceId, CancellationToken cancellationToken = default);
    IAsyncEnumerable<RealtimeEvent> ListenRealtimeAsync(CancellationToken cancellationToken = default);
}

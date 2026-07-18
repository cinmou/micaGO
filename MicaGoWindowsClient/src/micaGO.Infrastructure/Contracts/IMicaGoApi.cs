using MicaGo.Core.Models;

namespace MicaGo.Infrastructure.Contracts;

public interface IMicaGoApi : IDisposable
{
    string BaseUrl { get; }
    Task<IReadOnlyList<ChatSummary>> GetChatsAsync(CancellationToken cancellationToken = default);
    Task<IReadOnlyList<Message>> GetMessagesAsync(string chatId, int limit = 50, int offset = 0, CancellationToken cancellationToken = default);
    Task<Message> SendTextAsync(string chatId, string text, CancellationToken cancellationToken = default);
}

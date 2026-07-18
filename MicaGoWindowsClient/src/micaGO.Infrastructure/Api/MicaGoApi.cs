using System.Globalization;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using MicaGo.Core.Models;
using MicaGo.Infrastructure.Contracts;

namespace MicaGo.Infrastructure.Api;

public sealed class MicaGoApi : IMicaGoApi
{
    private readonly HttpClient _http;

    public MicaGoApi(string baseUrl, string token)
    {
        BaseUrl = baseUrl.TrimEnd('/');
        _http = new HttpClient
        {
            BaseAddress = new Uri($"{BaseUrl}/"),
            Timeout = TimeSpan.FromSeconds(20),
        };
        _http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        _http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
    }

    public string BaseUrl { get; }

    public async Task<IReadOnlyList<ChatSummary>> GetChatsAsync(CancellationToken cancellationToken = default)
    {
        using var document = await GetJsonAsync("api/chats?limit=250", cancellationToken);
        if (!document.RootElement.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array)
        {
            throw new MicaGoApiException("The server returned an invalid chat list.");
        }

        return data.EnumerateArray()
            .Where(element => element.ValueKind == JsonValueKind.Object)
            .Select(MapChat)
            .Where(chat => chat.Id.Length > 0)
            .OrderByDescending(chat => chat.IsPinned)
            .ToArray();
    }

    public async Task<IReadOnlyList<Message>> GetMessagesAsync(
        string chatId,
        int limit = 50,
        int offset = 0,
        CancellationToken cancellationToken = default)
    {
        var encoded = Uri.EscapeDataString(chatId);
        using var document = await GetJsonAsync(
            $"api/chats/{encoded}/messages?limit={limit}&offset={offset}&includeEmpty=false",
            cancellationToken);
        if (!document.RootElement.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array)
        {
            throw new MicaGoApiException("The server returned an invalid message list.");
        }

        return data.EnumerateArray()
            .Where(element => element.ValueKind == JsonValueKind.Object)
            .Select(element => MapMessage(element, chatId))
            .Where(message => message.Id.Length > 0)
            .Reverse()
            .ToArray();
    }

    public async Task<Message> SendTextAsync(
        string chatId,
        string text,
        CancellationToken cancellationToken = default)
    {
        var encoded = Uri.EscapeDataString(chatId);
        var payload = new
        {
            tempGuid = Guid.NewGuid().ToString("N"),
            message = text,
        };
        using var response = await _http.PostAsJsonAsync($"api/chats/{encoded}/send", payload, cancellationToken);
        using var document = await ReadJsonResponseAsync(response, cancellationToken);
        return MapMessage(document.RootElement, chatId);
    }

    private async Task<JsonDocument> GetJsonAsync(string path, CancellationToken cancellationToken)
    {
        using var response = await _http.GetAsync(path, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        return await ReadJsonResponseAsync(response, cancellationToken);
    }

    private static async Task<JsonDocument> ReadJsonResponseAsync(
        HttpResponseMessage response,
        CancellationToken cancellationToken)
    {
        if (!response.IsSuccessStatusCode)
        {
            var message = response.StatusCode == System.Net.HttpStatusCode.Unauthorized
                ? "The server rejected the saved token. Pair again."
                : $"The server returned HTTP {(int)response.StatusCode}.";
            throw new MicaGoApiException(message, (int)response.StatusCode);
        }

        try
        {
            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
            return await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken);
        }
        catch (JsonException exception)
        {
            throw new MicaGoApiException("The server returned invalid JSON.", (int)response.StatusCode, exception);
        }
    }

    private static ChatSummary MapChat(JsonElement json)
    {
        var id = GetString(json, "guid") ?? string.Empty;
        var displayName = GetString(json, "displayName");
        var identifier = GetString(json, "chatIdentifier");
        var participants = GetStringArray(json, "participants");
        var isGroup = GetBoolean(json, "isGroup") ?? id.Contains(";+;", StringComparison.Ordinal) || participants.Count > 1;
        var title = !string.IsNullOrWhiteSpace(displayName)
            ? displayName
            : isGroup && participants.Count > 0
                ? BuildGroupTitle(participants)
                : identifier ?? id;
        var preview = GetString(json, "latestRenderablePreview") ??
                      GetString(json, "lastMessagePreview") ??
                      GetString(json, "lastMessage") ??
                      string.Empty;
        var timestamp = GetLong(json, "latestRenderableAt") ??
                        GetLong(json, "lastMessageAt") ??
                        GetLong(json, "lastMessageDate");
        var service = GetString(json, "effectiveService") ??
                      GetString(json, "serviceCategory") ??
                      GetString(json, "serviceName") ??
                      "unknown";

        return new ChatSummary(
            id,
            string.IsNullOrWhiteSpace(title) ? "Conversation" : title,
            string.IsNullOrWhiteSpace(preview) ? "[Attachment]" : preview,
            FormatListTime(timestamp),
            GetInt(json, "unreadCount") ?? 0,
            BuildInitials(title),
            GetBoolean(json, "isMuted") ?? false,
            FormatService(service),
            GetBoolean(json, "canSendText") ?? service.Equals("imessage", StringComparison.OrdinalIgnoreCase),
            GetBoolean(json, "isPinned") ?? false,
            isGroup);
    }

    private static Message MapMessage(JsonElement json, string chatId)
    {
        var dateCreated = GetLong(json, "dateCreated");
        var isOutgoing = GetBoolean(json, "isFromMe") ?? false;
        var isRead = GetBoolean(json, "isRead") ?? false;
        var isDelivered = GetBoolean(json, "isDelivered") ?? false;
        var state = !isOutgoing
            ? MessageDeliveryState.Read
            : isRead
                ? MessageDeliveryState.Read
                : isDelivered
                    ? MessageDeliveryState.Delivered
                    : MessageDeliveryState.Sent;
        var attachmentLabel = BuildAttachmentLabel(json);
        var handle = json.TryGetProperty("handle", out var handleJson) && handleJson.ValueKind == JsonValueKind.Object
            ? GetString(handleJson, "id")
            : null;

        return new Message(
            GetString(json, "guid") ?? GetString(json, "tempGuid") ?? Guid.NewGuid().ToString("N"),
            GetString(json, "chatGuid") ?? chatId,
            GetString(json, "text") ?? string.Empty,
            FormatMessageTime(dateCreated),
            isOutgoing,
            state,
            isOutgoing ? null : handle,
            attachmentLabel);
    }

    private static string? BuildAttachmentLabel(JsonElement message)
    {
        if (!message.TryGetProperty("attachments", out var attachments) || attachments.ValueKind != JsonValueKind.Array)
        {
            return null;
        }

        var first = attachments.EnumerateArray().FirstOrDefault();
        if (first.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        var name = GetString(first, "transferName") ?? GetString(first, "filename") ?? "Attachment";
        var count = attachments.GetArrayLength();
        return count > 1 ? $"{name} + {count - 1} more" : name;
    }

    private static string BuildGroupTitle(IReadOnlyList<string> participants)
    {
        var names = participants
            .Select(value => value.Trim())
            .Where(value => value.Length > 0)
            .Take(4)
            .ToArray();
        return names.Length switch
        {
            0 => "Group Chat",
            1 => names[0],
            _ => string.Join(", ", names),
        };
    }

    private static string BuildInitials(string? title)
    {
        var words = (title ?? string.Empty)
            .Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (words.Length == 0 || char.IsDigit(words[0][0]) || words[0][0] == '+')
        {
            return "#";
        }

        return words.Length == 1
            ? words[0][..1].ToUpper(CultureInfo.CurrentCulture)
            : string.Concat(words[0][..1], words[1][..1]).ToUpper(CultureInfo.CurrentCulture);
    }

    private static string FormatService(string value) => value.Trim().ToLowerInvariant() switch
    {
        "imessage" => "iMessage",
        "sms" => "SMS",
        "rcs" => "RCS",
        _ => "Unknown",
    };

    private static string FormatListTime(long? milliseconds)
    {
        if (milliseconds is null or <= 0)
        {
            return string.Empty;
        }

        var local = DateTimeOffset.FromUnixTimeMilliseconds(milliseconds.Value).ToLocalTime();
        return local.Date == DateTimeOffset.Now.Date
            ? local.ToString("HH:mm", CultureInfo.CurrentCulture)
            : local.ToString("MMM d", CultureInfo.CurrentCulture);
    }

    private static string FormatMessageTime(long? milliseconds) => milliseconds is null or <= 0
        ? DateTime.Now.ToString("HH:mm", CultureInfo.CurrentCulture)
        : DateTimeOffset.FromUnixTimeMilliseconds(milliseconds.Value).ToLocalTime().ToString("HH:mm", CultureInfo.CurrentCulture);

    private static string? GetString(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static int? GetInt(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.TryGetInt32(out var result) ? result : null;

    private static long? GetLong(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.TryGetInt64(out var result) ? result : null;

    private static bool? GetBoolean(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind is JsonValueKind.True or JsonValueKind.False
            ? value.GetBoolean()
            : null;

    private static IReadOnlyList<string> GetStringArray(JsonElement element, string name) =>
        element.TryGetProperty(name, out var values) && values.ValueKind == JsonValueKind.Array
            ? values.EnumerateArray()
                .Where(value => value.ValueKind == JsonValueKind.String)
                .Select(value => value.GetString()!)
                .ToArray()
            : [];

    public void Dispose()
    {
        _http.Dispose();
    }
}

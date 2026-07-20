using System.Globalization;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Net;
using System.Net.WebSockets;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using MicaGo.Core.Models;
using MicaGo.Infrastructure.Contracts;

namespace MicaGo.Infrastructure.Api;

public sealed class MicaGoApi : IMicaGoApi
{
    private readonly HttpClient _http;
    private readonly string _token;
    private readonly Uri _webSocketUri;

    public MicaGoApi(string baseUrl, string webSocketUrl, string token)
    {
        BaseUrl = baseUrl.TrimEnd('/');
        _token = token;
        _webSocketUri = new Uri(webSocketUrl);
        _http = new HttpClient
        {
            BaseAddress = new Uri($"{BaseUrl}/"),
            Timeout = TimeSpan.FromSeconds(30),
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

        return data.EnumerateArray().WhereObject().Select(MapChat)
            .Where(chat => chat.Id.Length > 0)
            .OrderByDescending(chat => chat.IsPinned)
            .ThenByDescending(chat => chat.UpdatedAt)
            .ToArray();
    }

    public async Task<IReadOnlyList<Message>> GetMessagesAsync(string chatId, int limit = 50, int offset = 0, CancellationToken cancellationToken = default)
    {
        var encoded = Uri.EscapeDataString(chatId);
        using var document = await GetJsonAsync($"api/chats/{encoded}/messages?limit={limit}&offset={offset}&includeEmpty=false", cancellationToken);
        if (!document.RootElement.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array)
        {
            throw new MicaGoApiException("The server returned an invalid message list.");
        }

        return data.EnumerateArray().WhereObject().Select(element => MapMessage(element, chatId))
            .Where(message => message.Id.Length > 0).Reverse().ToArray();
    }

    public async Task<MessageDelta> GetMessagesDeltaAsync(long? since, int limit = 200, CancellationToken cancellationToken = default)
    {
        var path = $"api/messages/delta?limit={limit}" + (since is null ? string.Empty : $"&since={since.Value}");
        using var document = await GetJsonAsync(path, cancellationToken);
        var root = document.RootElement;
        var messages = root.TryGetProperty("messages", out var rows) && rows.ValueKind == JsonValueKind.Array
            ? rows.EnumerateArray().WhereObject().Select(row => MapMessage(row, GetString(row, "chatGuid") ?? string.Empty)).ToArray()
            : [];
        var chats = GetStringArray(root, "chatGuids");
        return new MessageDelta(messages, chats, GetLong(root, "cursor") ?? since ?? -1, GetBoolean(root, "hasMore") ?? false);
    }

    public async Task<Message> SendTextAsync(string chatId, string text, string? tempId = null, CancellationToken cancellationToken = default)
    {
        var encoded = Uri.EscapeDataString(chatId);
        var payload = new { tempGuid = tempId ?? Guid.NewGuid().ToString("N"), message = text };
        using var response = await _http.PostAsJsonAsync($"api/chats/{encoded}/send", payload, cancellationToken);
        using var document = await ReadJsonResponseAsync(response, cancellationToken);
        return MapMessage(document.RootElement, chatId);
    }

    public async Task<AttachmentUploadResult> SendAttachmentAsync(string chatId, string tempId, string filePath, bool isAudioMessage = false, IProgress<double>? progress = null, CancellationToken cancellationToken = default)
    {
        await using var file = File.OpenRead(filePath);
        using var multipart = new MultipartFormDataContent();
        multipart.Add(new StringContent(tempId), "tempGuid");
        if (isAudioMessage)
        {
            multipart.Add(new StringContent("true"), "isAudioMessage");
        }
        var content = new ProgressStreamContent(file, progress);
        content.Headers.ContentType = new MediaTypeHeaderValue(MimeFor(filePath));
        multipart.Add(content, "file", Path.GetFileName(filePath));
        using var response = await _http.PostAsync($"api/chats/{Uri.EscapeDataString(chatId)}/send-attachment", multipart, cancellationToken);
        using var document = await ReadJsonResponseAsync(response, cancellationToken);
        return new AttachmentUploadResult(GetString(document.RootElement, "filename"));
    }

    public async Task<byte[]> GetAttachmentBytesAsync(string attachmentId, bool preview = false, bool playable = false, CancellationToken cancellationToken = default)
    {
        var suffix = playable ? "/playable" : preview ? "/preview" : string.Empty;
        using var response = await _http.GetAsync($"api/attachments/{Uri.EscapeDataString(attachmentId)}{suffix}", HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            throw new MicaGoApiException($"The server returned HTTP {(int)response.StatusCode}.", (int)response.StatusCode);
        }
        return await response.Content.ReadAsByteArrayAsync(cancellationToken);
    }

    public async Task<MessageActionCapabilities> GetMessageActionCapabilitiesAsync(CancellationToken cancellationToken = default)
    {
        using var document = await GetJsonAsync("api/messages/actions/capabilities", cancellationToken);
        var root = document.RootElement;
        return new MessageActionCapabilities(GetBoolean(root, "edit") ?? false, GetBoolean(root, "retract") ?? false, GetBoolean(root, "delete") ?? false, GetString(root, "reason"));
    }

    public Task EditMessageAsync(string chatId, string messageId, string text, int partIndex = 0, CancellationToken cancellationToken = default) =>
        SendActionAsync(HttpMethod.Post, $"api/chats/{Uri.EscapeDataString(chatId)}/messages/{Uri.EscapeDataString(messageId)}/edit", new { text, partIndex }, cancellationToken);

    public Task RetractMessageAsync(string chatId, string messageId, int partIndex = 0, CancellationToken cancellationToken = default) =>
        SendActionAsync(HttpMethod.Post, $"api/chats/{Uri.EscapeDataString(chatId)}/messages/{Uri.EscapeDataString(messageId)}/retract", new { partIndex }, cancellationToken);

    public Task DeleteMessageAsync(string chatId, string messageId, CancellationToken cancellationToken = default) =>
        SendActionAsync(HttpMethod.Delete, $"api/chats/{Uri.EscapeDataString(chatId)}/messages/{Uri.EscapeDataString(messageId)}", null, cancellationToken);

    public async Task<bool> GetTestContactEnabledAsync(CancellationToken cancellationToken = default)
    {
        using var document = await GetJsonAsync("api/test-contact", cancellationToken);
        return GetBoolean(document.RootElement, "enabled") ?? false;
    }

    public Task SetTestContactEnabledAsync(bool enabled, CancellationToken cancellationToken = default) =>
        SendActionAsync(HttpMethod.Put, "api/test-contact", new { enabled }, cancellationToken);

    public async IAsyncEnumerable<RealtimeEvent> ListenRealtimeAsync([EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        using var socket = new ClientWebSocket();
        socket.Options.SetRequestHeader("Authorization", $"Bearer {_token}");
        await socket.ConnectAsync(_webSocketUri, cancellationToken);
        var buffer = new byte[64 * 1024];
        while (socket.State == WebSocketState.Open && !cancellationToken.IsCancellationRequested)
        {
            using var payload = new MemoryStream();
            WebSocketReceiveResult result;
            do
            {
                result = await socket.ReceiveAsync(buffer, cancellationToken);
                if (result.MessageType == WebSocketMessageType.Close) yield break;
                payload.Write(buffer, 0, result.Count);
            } while (!result.EndOfMessage);
            if (result.MessageType != WebSocketMessageType.Text) continue;
            RealtimeEvent? realtimeEvent = null;
            try
            {
                using var json = JsonDocument.Parse(payload.ToArray());
                var root = json.RootElement;
                var data = root.TryGetProperty("data", out var nested) && nested.ValueKind == JsonValueKind.Object ? nested : root;
                var type = GetString(root, "type") ?? "message:updated";
                var chatGuid = GetString(data, "chatGuid");
                var messageGuid = GetString(data, "guid") ?? GetString(data, "messageGuid");
                // message:* frames carry the full message JSON — parse it so read
                // receipts / edits / unsends apply even when the rowid-based
                // delta cursor never re-surfaces the row.
                Message? parsed = null;
                if (type.StartsWith("message:", StringComparison.OrdinalIgnoreCase)
                    && messageGuid is not null
                    && chatGuid is not null
                    && data.TryGetProperty("text", out _))
                {
                    parsed = MapMessage(data, chatGuid);
                }
                realtimeEvent = new RealtimeEvent(type, chatGuid, messageGuid, parsed);
            }
            catch (JsonException)
            {
                // Ignore malformed realtime hints; delta remains authoritative.
            }
            if (realtimeEvent is not null) yield return realtimeEvent;
        }
    }

    private async Task SendActionAsync(HttpMethod method, string path, object? payload, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(method, path);
        if (payload is not null) request.Content = JsonContent.Create(payload);
        using var response = await _http.SendAsync(request, cancellationToken);
        using var _ = await ReadJsonResponseAsync(response, cancellationToken);
    }

    private async Task<JsonDocument> GetJsonAsync(string path, CancellationToken cancellationToken)
    {
        using var response = await _http.GetAsync(path, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        return await ReadJsonResponseAsync(response, cancellationToken);
    }

    private static async Task<JsonDocument> ReadJsonResponseAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        if (!response.IsSuccessStatusCode)
        {
            var message = response.StatusCode == System.Net.HttpStatusCode.Unauthorized ? "The server rejected the saved token. Pair again." : $"The server returned HTTP {(int)response.StatusCode}.";
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
        var title = !string.IsNullOrWhiteSpace(displayName) ? displayName : isGroup && participants.Count > 0 ? BuildGroupTitle(participants) : identifier ?? id;
        var preview = GetString(json, "latestRenderablePreview") ?? GetString(json, "lastMessagePreview") ?? GetString(json, "lastMessage") ?? string.Empty;
        var timestamp = GetLong(json, "latestRenderableAt") ?? GetLong(json, "lastMessageAt") ?? GetLong(json, "lastMessageDate") ?? 0;
        var service = GetString(json, "effectiveService") ?? GetString(json, "serviceCategory") ?? GetString(json, "serviceName") ?? "unknown";
        return new ChatSummary(id, string.IsNullOrWhiteSpace(title) ? "Conversation" : title, string.IsNullOrWhiteSpace(preview) ? "[Attachment]" : preview, string.Empty, GetInt(json, "unreadCount") ?? 0, BuildInitials(title), GetBoolean(json, "isMuted") ?? false, FormatService(service), GetBoolean(json, "canSendText") ?? service.Equals("imessage", StringComparison.OrdinalIgnoreCase), GetBoolean(json, "isPinned") ?? false, isGroup, timestamp, participants, LatestFromMe: GetBoolean(json, "latestRenderableFromMe") ?? false);
    }

    private static Message MapMessage(JsonElement json, string chatId)
    {
        var dateCreated = GetLong(json, "dateCreated") ?? 0;
        var isOutgoing = GetBoolean(json, "isFromMe") ?? false;
        var state = !isOutgoing ? MessageDeliveryState.Read : GetBoolean(json, "isRead") == true ? MessageDeliveryState.Read : GetBoolean(json, "isDelivered") == true ? MessageDeliveryState.Delivered : MessageDeliveryState.Sent;
        var attachments = MapAttachments(json);
        var handle = json.TryGetProperty("handle", out var handleJson) && handleJson.ValueKind == JsonValueKind.Object ? GetString(handleJson, "id") : null;
        return new Message(GetString(json, "guid") ?? GetString(json, "tempGuid") ?? Guid.NewGuid().ToString("N"), GetString(json, "chatGuid") ?? chatId, GetString(json, "text") ?? string.Empty, FormatMessageTime(dateCreated), isOutgoing, state, isOutgoing ? null : handle, BuildAttachmentLabel(attachments), dateCreated, attachments, GetString(json, "associatedMessageGuid"), GetInt(json, "associatedMessageType") ?? 0, GetString(json, "threadOriginatorGuid"), GetString(json, "expressiveSendStyleId"), GetBoolean(json,"isEdited")==true||(GetLong(json, "dateEdited") ?? 0) > 0, Subject:GetString(json,"subject"), SemanticKind:GetString(json,"semanticKind"), RenderRecommendation:GetString(json,"renderRecommendation"), IsRetracted:GetBoolean(json,"isRetracted")==true||(GetLong(json,"dateRetracted")??0)>0, ItemType:GetInt(json,"itemType")??0, GroupActionType:GetInt(json,"groupActionType")??0, GroupTitle:GetString(json,"groupTitle"), BalloonBundleId:GetString(json,"balloonBundleId"), SenderIdentity:handle);
    }

    private static IReadOnlyList<Attachment> MapAttachments(JsonElement message)
    {
        if (!message.TryGetProperty("attachments", out var rows) || rows.ValueKind != JsonValueKind.Array) return [];
        return rows.EnumerateArray().WhereObject().Select(row => new Attachment(
            GetString(row, "guid") ?? string.Empty,
            GetString(row, "transferName") ?? GetString(row, "filename") ?? "Attachment",
            GetString(row, "mimeType") ?? string.Empty,
            GetLong(row, "totalBytes") ?? 0,
            GetString(row, "attachmentKind"),
            GetString(row, "previewUrl"),
            GetBoolean(row, "isSticker") ?? false,
            GetInt(row, "width") ?? 0,
            GetInt(row, "height") ?? 0,
            GetString(row,"originalMimeType"),
            GetString(row,"uti"),
            GetBoolean(row,"isVoiceMessage")??false,
            GetString(row,"displayKind"),
            GetBoolean(row,"needsPreviewConversion")??false)).Where(item => item.Id.Length > 0).ToArray();
    }

    private static string? BuildAttachmentLabel(IReadOnlyList<Attachment> attachments) => attachments.Count == 0 ? null : attachments.Count > 1 ? $"{attachments[0].FileName} + {attachments.Count - 1} more" : attachments[0].FileName;
    private static string BuildGroupTitle(IReadOnlyList<string> participants) => participants.Count == 0 ? "Group Chat" : string.Join(", ", participants.Take(4));
    private static string BuildInitials(string? title) { var words = (title ?? string.Empty).Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries); return words.Length == 0 || char.IsDigit(words[0][0]) || words[0][0] == '+' ? "#" : words.Length == 1 ? words[0][..1].ToUpper(CultureInfo.CurrentCulture) : string.Concat(words[0][..1], words[1][..1]).ToUpper(CultureInfo.CurrentCulture); }
    private static string FormatService(string value) => value.Trim().ToLowerInvariant() switch { "imessage" => "iMessage", "sms" => "SMS", "rcs" => "RCS", _ => "Unknown" };
    private static string FormatMessageTime(long milliseconds) => milliseconds <= 0 ? DateTime.Now.ToString("HH:mm", CultureInfo.CurrentCulture) : DateTimeOffset.FromUnixTimeMilliseconds(milliseconds).ToLocalTime().ToString("HH:mm", CultureInfo.CurrentCulture);
    private static string MimeFor(string path) => Path.GetExtension(path).ToLowerInvariant() switch { ".jpg" or ".jpeg" => "image/jpeg", ".png" => "image/png", ".gif" => "image/gif", ".mp4" => "video/mp4", ".mov" => "video/quicktime", ".m4a" => "audio/mp4", ".mp3" => "audio/mpeg", ".wav" => "audio/wav", ".pdf" => "application/pdf", _ => "application/octet-stream" };
    private static string? GetString(JsonElement element, string name) => element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    private static int? GetInt(JsonElement element, string name) => element.TryGetProperty(name, out var value) && value.TryGetInt32(out var result) ? result : null;
    private static long? GetLong(JsonElement element, string name) => element.TryGetProperty(name, out var value) && value.TryGetInt64(out var result) ? result : null;
    private static bool? GetBoolean(JsonElement element, string name) => element.TryGetProperty(name, out var value) && value.ValueKind is JsonValueKind.True or JsonValueKind.False ? value.GetBoolean() : null;
    private static IReadOnlyList<string> GetStringArray(JsonElement element, string name) => element.TryGetProperty(name, out var values) && values.ValueKind == JsonValueKind.Array ? values.EnumerateArray().Where(value => value.ValueKind == JsonValueKind.String).Select(value => value.GetString()!).ToArray() : [];

    public void Dispose() => _http.Dispose();

    private sealed class ProgressStreamContent(Stream source, IProgress<double>? progress) : HttpContent
    {
        protected override bool TryComputeLength(out long length) { length = source.Length; return true; }
        protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context)
        {
            var buffer = new byte[81920]; long sent = 0; int read;
            while ((read = await source.ReadAsync(buffer)) > 0) { await stream.WriteAsync(buffer.AsMemory(0, read)); sent += read; progress?.Report(source.Length == 0 ? 1 : (double)sent / source.Length); }
        }
    }
}

file static class JsonElementEnumerableExtensions
{
    public static IEnumerable<JsonElement> WhereObject(this JsonElement.ArrayEnumerator values) => values.Where(value => value.ValueKind == JsonValueKind.Object);
}

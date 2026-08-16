using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json.Serialization;

namespace MicaGo.Core.Models;

/// <summary>
/// Stable identity object for a row in the conversation list. Realtime updates
/// mutate the existing row so WinUI does not discard and recreate its container
/// just because the preview, timestamp, or unread badge changed.
/// </summary>
public sealed record ChatSummary : INotifyPropertyChanged
{
    private string _title;
    private string _preview;
    private string _time;
    private int _unreadCount;
    private string _initials;
    private bool _isMuted;
    private string _serviceLabel;
    private bool _canSendText;
    private bool _isPinned;
    private bool _isGroup;
    private long _updatedAt;
    private IReadOnlyList<string>? _participants;
    private string? _avatarPath;
    private IReadOnlyList<string>? _routeIds;
    private bool _latestFromMe;
    private bool _hasUnread;
    private string? _primaryRouteId;
    private string? _contactId;

    public ChatSummary(
        string Id,
        string Title,
        string Preview,
        string Time,
        int UnreadCount,
        string Initials,
        bool IsMuted = false,
        string ServiceLabel = "Unknown",
        bool CanSendText = false,
        bool IsPinned = false,
        bool IsGroup = false,
        long UpdatedAt = 0,
        IReadOnlyList<string>? Participants = null,
        string? AvatarPath = null,
        IReadOnlyList<string>? RouteIds = null,
        bool LatestFromMe = false,
        bool HasUnread = false,
        string? PrimaryRouteId = null,
        string? ContactId = null)
    {
        this.Id = Id;
        _title = Title;
        _preview = Preview;
        _time = Time;
        _unreadCount = UnreadCount;
        _initials = Initials;
        _isMuted = IsMuted;
        _serviceLabel = ServiceLabel;
        _canSendText = CanSendText;
        _isPinned = IsPinned;
        _isGroup = IsGroup;
        _updatedAt = UpdatedAt;
        _participants = Participants;
        _avatarPath = AvatarPath;
        _routeIds = RouteIds;
        _latestFromMe = LatestFromMe;
        _hasUnread = HasUnread;
        _primaryRouteId = PrimaryRouteId;
        _contactId = ContactId;
    }

    // A record's generated copy constructor would also copy the
    // PropertyChanged delegate. Keep `with` support without leaking a row's UI
    // subscribers into the short-lived snapshot produced by the ViewModel.
    private ChatSummary(ChatSummary source)
    {
        Id = source.Id;
        _title = source.Title;
        _preview = source.Preview;
        _time = source.Time;
        _unreadCount = source.UnreadCount;
        _initials = source.Initials;
        _isMuted = source.IsMuted;
        _serviceLabel = source.ServiceLabel;
        _canSendText = source.CanSendText;
        _isPinned = source.IsPinned;
        _isGroup = source.IsGroup;
        _updatedAt = source.UpdatedAt;
        _participants = source.Participants;
        _avatarPath = source.AvatarPath;
        _routeIds = source.RouteIds;
        _latestFromMe = source.LatestFromMe;
        _hasUnread = source.HasUnread;
        _primaryRouteId = source._primaryRouteId;
        _contactId = source._contactId;
    }

    public string Id { get; init; }
    public string Title { get => _title; init => _title = value; }
    public string Preview { get => _preview; init => _preview = value; }
    public string Time { get => _time; init => _time = value; }
    public int UnreadCount { get => _unreadCount; init => _unreadCount = value; }
    public string Initials { get => _initials; init => _initials = value; }
    public bool IsMuted { get => _isMuted; init => _isMuted = value; }
    public string ServiceLabel { get => _serviceLabel; init => _serviceLabel = value; }
    public bool CanSendText { get => _canSendText; init => _canSendText = value; }
    public bool IsPinned { get => _isPinned; init => _isPinned = value; }
    public bool IsGroup { get => _isGroup; init => _isGroup = value; }
    public long UpdatedAt { get => _updatedAt; init => _updatedAt = value; }
    public IReadOnlyList<string>? Participants { get => _participants; init => _participants = value; }
    public string? AvatarPath { get => _avatarPath; init => _avatarPath = value; }
    public IReadOnlyList<string>? RouteIds { get => _routeIds; init => _routeIds = value; }
    public bool LatestFromMe { get => _latestFromMe; init => _latestFromMe = value; }
    public bool HasUnread { get => _hasUnread; init => _hasUnread = value; }
    [JsonIgnore]
    public string PrimaryRouteId { get => string.IsNullOrWhiteSpace(_primaryRouteId) ? Id : _primaryRouteId; init => _primaryRouteId = value; }
    [JsonIgnore]
    public string? ContactId { get => _contactId; init => _contactId = value; }

    /// <summary>
    /// Stable identity used only by the visible chat list. A merged contact may
    /// switch its newest route without becoming a different list row.
    /// </summary>
    [JsonIgnore]
    public string ListKey
    {
        get
        {
            if(!string.IsNullOrWhiteSpace(ContactId))return "contact:"+ContactId.ToUpperInvariant();
            var routes = RouteIds is { Count: > 0 } ? RouteIds : [Id];
            if (routes.Count == 1) return "route:" + routes[0].ToUpperInvariant();
            return "routes:" + string.Join('\u001f', routes.Order(StringComparer.OrdinalIgnoreCase).Select(route => route.ToUpperInvariant()));
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public void UpdateFrom(ChatSummary source)
    {
        Set(ref _title, source.Title, nameof(Title));
        Set(ref _preview, source.Preview, nameof(Preview));
        Set(ref _time, source.Time, nameof(Time));
        Set(ref _unreadCount, source.UnreadCount, nameof(UnreadCount));
        Set(ref _initials, source.Initials, nameof(Initials));
        Set(ref _isMuted, source.IsMuted, nameof(IsMuted));
        Set(ref _serviceLabel, source.ServiceLabel, nameof(ServiceLabel));
        Set(ref _canSendText, source.CanSendText, nameof(CanSendText));
        Set(ref _isPinned, source.IsPinned, nameof(IsPinned));
        Set(ref _isGroup, source.IsGroup, nameof(IsGroup));
        Set(ref _updatedAt, source.UpdatedAt, nameof(UpdatedAt));
        SetSequence(ref _participants, source.Participants, nameof(Participants));
        Set(ref _avatarPath, source.AvatarPath, nameof(AvatarPath));
        SetSequence(ref _routeIds, source.RouteIds, nameof(RouteIds));
        Set(ref _latestFromMe, source.LatestFromMe, nameof(LatestFromMe));
        Set(ref _hasUnread, source.HasUnread, nameof(HasUnread));
        Set(ref _primaryRouteId, source._primaryRouteId, nameof(PrimaryRouteId));
        Set(ref _contactId, source._contactId, nameof(ContactId));
    }

    private void Set<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }

    private void SetSequence(ref IReadOnlyList<string>? field, IReadOnlyList<string>? value, string propertyName)
    {
        if (ReferenceEquals(field, value)) return;
        if (field is null && value is null) return;
        if (field is not null && value is not null && field.SequenceEqual(value, StringComparer.OrdinalIgnoreCase)) return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}

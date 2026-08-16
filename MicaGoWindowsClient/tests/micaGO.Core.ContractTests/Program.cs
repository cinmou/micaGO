using MicaGo.Core.Connection;
using MicaGo.Core.Models;
using MicaGo.Infrastructure.Contacts;
using MicaGo.Infrastructure.Connection;

var tests = new (string Name, Action Run)[]
{
    ("v1 payload", ParsesV1),
    ("v2 LAN first payload", ParsesV2),
    ("v3 candidate filtering", ParsesV3),
    ("missing token rejection", RejectsMissingToken),
    ("websocket derivation", DerivesWebSocketUrl),
    ("attachment placeholder reconciliation", ReconcilesAttachmentPlaceholder),
    ("ambiguous attachment fallback", RefusesAmbiguousAttachmentFallback),
    ("stable presentation key", PreservesPresentationKey),
    ("route-qualified message identity", KeepsRouteQualifiedMessagesDistinct),
    ("attachment preview normalization", NormalizesAttachmentPreviews),
    ("stable chat row notifications", UpdatesChatRowInPlace),
    ("stable merged contact reorder", KeepsMergedContactRowStable),
    ("stable message row notifications", UpdatesMessageRowInPlace),
    ("vCard folded and escaped contacts", ParsesVCardContacts),
    ("private and group presentation", PresentsPrivateAndGroupThreads),
    ("reaction and system merging", MergesReactionAndSystemRows),
    ("Twemoji flag-only segmentation", SegmentsOnlyFlagEmoji),
    ("Twemoji Emoji 17 fallback segmentation", SegmentsEmoji17Fallback),
    ("native Windows device registration", BuildsWindowsDeviceRegistration),
    ("late snapshot keeps live rows", MergeSnapshotKeepsLiveRows),
    ("snapshot rejects rows from another chat", MergeSnapshotRejectsOtherChats),
    ("snapshot confirms rapid pending rows one-to-one", MergeSnapshotConfirmsPendingOneToOne),
    ("footer follows latest optimistic send state", FooterFollowsLatestOptimisticSend),
    ("Flutter-compatible link preview metadata", ParsesLinkPreviewMetadata),
    ("update check version compare", ComparesReleaseVersions),
    ("snapshot drops server-side deletes", MergeSnapshotDropsDeletedRows),
};

var failures = 0;
foreach (var test in tests)
{
    try
    {
        test.Run();
        Console.WriteLine($"PASS {test.Name}");
    }
    catch (Exception exception)
    {
        failures++;
        Console.Error.WriteLine($"FAIL {test.Name}: {exception.Message}");
    }
}

try { await RealtimeSyncTests.RunAsync(); Console.WriteLine("PASS realtime delta dedup and websocket hint"); }
catch(Exception exception){failures++;Console.Error.WriteLine($"FAIL realtime delta dedup and websocket hint: {exception.Message}");}
try { await HiddenChatStoreTests.RunAsync(); Console.WriteLine("PASS hidden contact persistence and selective restore"); }
catch(Exception exception){failures++;Console.Error.WriteLine($"FAIL hidden contact persistence and selective restore: {exception.Message}");}

return failures == 0 ? 0 : 1;

static void ParsesV1()
{
    var payload = PairingPayloadParser.Parse("""{"baseUrl":"https://go.example.com/path","websocketUrl":"wss://go.example.com/ws","token":"secret"}""");
    Equal(1, payload.Version);
    Equal("https://go.example.com", payload.Endpoints.Single().BaseUrl);
    Equal("wss://go.example.com/ws", payload.Endpoints.Single().WebSocketUrl);
}

static void ParsesV2()
{
    var payload = PairingPayloadParser.Parse("""
        {"version":2,"mode":"lanFirst","token":"secret","endpoints":[
          {"kind":"public","baseUrl":"https://public.example.com","priority":2},
          {"kind":"lan","baseUrl":"http://192.168.1.9:3000","priority":1}
        ]}
        """);
    Equal(ConnectionMode.LanFirst, payload.Mode);
    Equal(EndpointKind.Lan, payload.Endpoints[0].Kind);
    Equal(2, payload.Endpoints.Count);
}

static void ParsesV3()
{
    var payload = PairingPayloadParser.Parse("""
        {"version":3,"token":"secret","configRevision":"r2","candidates":[
          {"kind":"local","baseUrl":"http://127.0.0.1:3000"},
          {"kind":"lan","baseUrl":"http://192.168.1.8:3000","disabled":true},
          {"kind":"lan","baseUrl":"http://192.168.1.9:3000"},
          {"kind":"public","baseUrl":"https://go.example.com"}
        ]}
        """);
    Equal("r2", payload.ConfigRevision);
    Equal(2, payload.Endpoints.Count);
    True(payload.Endpoints.All(endpoint => endpoint.Kind != EndpointKind.Local));
}

static void RejectsMissingToken()
{
    try
    {
        PairingPayloadParser.Parse("""{"baseUrl":"https://go.example.com"}""");
    }
    catch (PairingPayloadException)
    {
        return;
    }

    throw new InvalidOperationException("Payload without a token was accepted.");
}

static void DerivesWebSocketUrl()
{
    Equal("ws://192.168.1.9:3000/ws", EndpointUrls.DeriveWebSocketUrl("http://192.168.1.9:3000/anything"));
    Equal("wss://go.example.com/ws", EndpointUrls.DeriveWebSocketUrl("https://go.example.com"));
}

static void ReconcilesAttachmentPlaceholder()
{
    var localAttachment = new Attachment("local-a", "photo.heic", "image/heic", 123);
    var serverAttachment = new Attachment("server-a", "photo.jpg", "image/jpeg", 456);
    var local = new Message("local-1", "chat", "", "", true, MessageDeliveryState.Sending, DateCreated: 1000, Attachments: [localAttachment], IsPending: true);
    var server = new Message("server-1", "chat", "\uFFFC", "", true, MessageDeliveryState.Sent, DateCreated: 1200, Attachments: [serverAttachment]);
    True(MessageSemantics.ShouldReconcile(local, server));
}

static void RefusesAmbiguousAttachmentFallback()
{
    var attachment = new Attachment("a", "first.jpg", "image/jpeg", 100);
    var one = new Message("local-1", "chat", "", "", true, MessageDeliveryState.Sending, DateCreated: 1000, Attachments: [attachment], IsPending: true);
    var two = one with { Id = "local-2", DateCreated = 1001, Attachments = [attachment with { FileName = "second.jpg", Size = 101 }] };
    var server = new Message("server", "chat", "", "", true, MessageDeliveryState.Sent, DateCreated: 1200, Attachments: [attachment with { FileName = "converted.bin", Size = 999 }]);
    True(MessageSemantics.MatchingPending([one, two], server) is null);
}

static void PreservesPresentationKey()
{
    var pending=new Message("local-1","chat","hello","",true,MessageDeliveryState.Sending,DateCreated:1000,IsPending:true,PresentationId:"row-1");
    var server=new Message("server-1","chat","hello","",true,MessageDeliveryState.Sent,DateCreated:1100);
    var confirmed=MessageSemantics.ReconcilePresentation(pending,server);
    Equal("row-1",confirmed.PresentationKey);
    Equal(1000L,confirmed.DateCreated);
    Equal("server-1",confirmed.Id);
    Equal(MessageDeliveryState.Sent,confirmed.DeliveryState);
}

static void NormalizesAttachmentPreviews()
{
    Equal("[Attachment]", MessageSemantics.PreviewText("obj"));
    Equal("[Attachment]", MessageSemantics.PreviewText("\uFFFC"));
    Equal("hello", MessageSemantics.PreviewText(" hello "));
    var attachment = new Attachment("a", "photo.heic", "image/heic", 123);
    var message = new Message("m", "chat", "object", "", false, MessageDeliveryState.Read, Attachments: [attachment]);
    Equal("[Attachment]", MessageSemantics.PreviewText(message));
}

static void UpdatesChatRowInPlace()
{
    var row = new ChatSummary("chat", "Jane", "old", "1m", 0, "J");
    var changed = new HashSet<string>();
    row.PropertyChanged += (_, args) => changed.Add(args.PropertyName!);
    row.UpdateFrom(row with { Preview = "new", Time = "now", UnreadCount = 1, HasUnread = true });
    Equal("new", row.Preview);
    Equal(1, row.UnreadCount);
    True(changed.SetEquals([nameof(ChatSummary.Preview), nameof(ChatSummary.Time), nameof(ChatSummary.UnreadCount), nameof(ChatSummary.HasUnread)]));
}

static void ParsesVCardContacts()
{
    var cards=VcfContactImporter.Parse("BEGIN:VCARD\r\nVERSION:3.0\r\nUID:urn:uuid:11111111-2222-3333-4444-555555555555\r\nFN:Doe\\, Jane\r\nEMAIL:jane@example.com\r\nTEL;TYPE=CELL:+1 555\r\n 0100\r\nPHOTO;ENCODING=b;TYPE=PNG:AQID\r\n BA==\r\nEND:VCARD\r\n");
    Equal(1,cards.Count);Equal("Doe, Jane",cards[0].DisplayName);Equal("jane@example.com",cards[0].Identities[0]);Equal("+1 5550100",cards[0].Identities[1]);Equal("image/png",cards[0].PhotoMimeType!);Equal(4,cards[0].PhotoBytes!.Length);Equal("11111111-2222-3333-4444-555555555555",cards[0].StableId!);
}

static void PresentsPrivateAndGroupThreads()
{
    var a=new Message("a","chat","one","10:00",false,MessageDeliveryState.Read,SenderName:"Jane",DateCreated:1000,SenderIdentity:"jane@example.com");
    var b=a with{Id="b",Text="two",DateCreated=2000};var outgoing=new Message("c","chat","ok","10:01",true,MessageDeliveryState.Delivered,DateCreated:3000);
    var group=ThreadPresentation.Build([a,b,outgoing],true,"en").Where(row=>!row.IsSeparator).ToArray();
    True(group[0].ShowSenderLabel);True(!group[0].ShowSenderAvatar);True(!group[1].ShowSenderLabel);True(group[1].ShowSenderAvatar);True(!group[2].ShowFooter);
    var direct=ThreadPresentation.Build([a,outgoing],false,"en").Where(row=>!row.IsSeparator).ToArray();
    True(!direct[0].ShowSenderLabel);True(!direct[0].ReserveSenderAvatarSpace);True(direct[1].ShowFooter);
}

static void MergesReactionAndSystemRows()
{
    var target=new Message("target","chat","hello","",false,MessageDeliveryState.Read,DateCreated:1000,SenderIdentity:"jane");
    var reaction=new Message("reaction","chat","","",true,MessageDeliveryState.Sent,DateCreated:1100,AssociatedMessageGuid:"p:0/target",AssociatedMessageType:2001);
    var system1=new Message("s1","chat","","",false,MessageDeliveryState.Read,DateCreated:2000,SemanticKind:"service_event");
    var system2=system1 with{Id="s2",DateCreated=2100};
    var rows=ThreadPresentation.Build([target,reaction,system1,system2],false,"en").Where(row=>!row.IsSeparator).ToArray();
    Equal(2,rows.Length);Equal("👍",rows[0].Reactions!.Single());Equal(2,rows[1].MergedSystemCount);True(rows[1].IsPresentationSystem);
}

static void SegmentsOnlyFlagEmoji()
{
    var segments = FlagEmojiSemantics.Split("A🇮🇪🏳️‍🌈🏳️‍⚧️🏴‍☠️🏁💀😀Z");
    Equal("1f1ee-1f1ea", segments.Single(item => item.Text == "🇮🇪").AssetKey!);
    Equal("1f3f3-fe0f-200d-1f308", segments.Single(item => item.Text == "🏳️‍🌈").AssetKey!);
    Equal("1f3f3-fe0f-200d-26a7-fe0f", segments.Single(item => item.Text == "🏳️‍⚧️").AssetKey!);
    Equal("1f3f4-200d-2620-fe0f", segments.Single(item => item.Text == "🏴‍☠️").AssetKey!);
    Equal("1f3c1", segments.Single(item => item.Text == "🏁").AssetKey!);
    True(segments.Single(item => item.Text.Contains("💀😀", StringComparison.Ordinal)).AssetKey is null);
}

static void SegmentsEmoji17Fallback()
{
    var segments = FlagEmojiSemantics.Split("A🇮🇪🫪🧑‍🩰😀Z", includeFlags: false, includeEmoji17: true);
    True(segments.Single(item => item.Text.Contains("🇮🇪", StringComparison.Ordinal)).AssetKey is null);
    Equal("1faea", segments.Single(item => item.Text == "🫪").AssetKey!);
    Equal("1f9d1-200d-1fa70", segments.Single(item => item.Text == "🧑‍🩰").AssetKey!);
    True(segments.Single(item => item.Text.Contains("😀", StringComparison.Ordinal)).AssetKey is null);
}

static void BuildsWindowsDeviceRegistration()
{
    var profile=new ConnectionProfile("micaGO","http://192.168.1.2:3000","ws://192.168.1.2:3000/ws",ConnectionMode.LanFirst,"",[
        new ConnectionEndpoint(EndpointKind.Lan,"http://192.168.1.2:3000","ws://192.168.1.2:3000/ws"),
        new ConnectionEndpoint(EndpointKind.Public,"https://go.example.com","wss://go.example.com/ws")]);
    var registration=DevicePresenceService.CreateRegistration(profile,"windows-test",true);
    Equal("windows-test",registration.Id);Equal("windows",registration.Platform);Equal("native",registration.ClientType);Equal("none",registration.PushProvider);Equal("lan_public",registration.Mode);True(registration.Background);True(!registration.PushEnabled);
}

// C74: SelectChatAsync loads three snapshots while realtime frames append rows.
// A wholesale replace let a late snapshot wipe live arrivals (they flickered in
// and vanished); the merge must keep them, and keep in-flight pending sends.
static void MergeSnapshotKeepsLiveRows()
{
    var older = new Message("m1", "chat", "one", "", false, MessageDeliveryState.Read, DateCreated: 1000);
    var live = new Message("m2", "chat", "live", "", false, MessageDeliveryState.Read, DateCreated: 3000);
    var pending = new Message("local-1", "chat", "typing", "", true, MessageDeliveryState.Sending, DateCreated: 3100, IsPending: true, PresentationId: "row-1");
    // The snapshot was taken before m2/local-1 existed.
    var merged = MessageSemantics.MergeSnapshot([older, live, pending], [older]);
    Equal(3, merged.Count);
    Equal("m1,m2,local-1", string.Join(',', merged.Select(row => row.Id)));
    Equal("row-1", merged[2].PresentationKey);
}

static void MergeSnapshotDropsDeletedRows()
{
    var kept = new Message("m1", "chat", "one", "", false, MessageDeliveryState.Read, DateCreated: 2000);
    var deleted = new Message("m0", "chat", "gone", "", false, MessageDeliveryState.Read, DateCreated: 1000);
    // A row older than the snapshot window that the snapshot no longer lists was
    // deleted server-side and must not be resurrected.
    var merged = MessageSemantics.MergeSnapshot([deleted, kept], [kept]);
    Equal(1, merged.Count);
    Equal("m1", merged[0].Id);
}

static void KeepsRouteQualifiedMessagesDistinct()
{
    var left=new Message("shared","route-a","hello","",false,MessageDeliveryState.Read,DateCreated:1000,SourceRowId:1);
    var right=new Message("shared","route-b","world","",false,MessageDeliveryState.Read,DateCreated:1001,SourceRowId:2);
    var merged=MessageSemantics.MergeSnapshot([], [left,right]);
    Equal(2,merged.Count);True(left.TimelineKey!=right.TimelineKey);
    var pending=new Message("local","route-a","same","",true,MessageDeliveryState.Sending,DateCreated:2000,IsPending:true);
    var confirmation=new Message("server","route-b","same","",true,MessageDeliveryState.Sent,DateCreated:2001);
    True(!MessageSemantics.ShouldReconcile(pending,confirmation));
}

static void KeepsMergedContactRowStable()
{
    var row = new ChatSummary("route-a", "Jane", "old", "1m", 0, "J", UpdatedAt: 100, RouteIds: ["route-a", "route-b"], PrimaryRouteId: "route-a", ContactId:"contact-jane");
    var refreshed = new ChatSummary("route-b", "Jane Renamed", "new", "now", 0, "J", UpdatedAt: 200, RouteIds: ["route-b", "route-a", "route-c"], PrimaryRouteId: "route-b", ContactId:"contact-jane");
    Equal(row.ListKey, refreshed.ListKey);
    row.UpdateFrom(refreshed);
    Equal("route-a", row.Id);
    Equal("route-b", row.PrimaryRouteId);
    Equal("new", row.Preview);Equal("Jane Renamed",row.Title);
    var json = System.Text.Json.JsonSerializer.Serialize(row);
    True(!json.Contains("ListKey", StringComparison.Ordinal));
    True(System.Text.Json.JsonSerializer.Deserialize<ChatSummary>(json) is not null);

    var other = new ChatSummary("route-c", "Alex", "hello", "2m", 0, "A", UpdatedAt: 150);
    var rows = new ChatListCollection { other, row };
    var moveCount = 0;
    var resetOrReplace = 0;
    ChatListMutationEventArgs? mutation = null;
    rows.CollectionChanged += (_, args) =>
    {
        if (args.Action == System.Collections.Specialized.NotifyCollectionChangedAction.Move) moveCount++;
        if (args.Action is System.Collections.Specialized.NotifyCollectionChangedAction.Reset or System.Collections.Specialized.NotifyCollectionChangedAction.Replace) resetOrReplace++;
    };
    rows.Mutated += (_, args) => mutation = args;
    rows.Apply([row, other], true);

    True(ReferenceEquals(row, rows[0]));
    Equal(1, moveCount);
    Equal(0, resetOrReplace);
    Equal(1, mutation?.Moves.Count ?? 0);
    True(mutation?.Animate == true);
}

static void UpdatesMessageRowInPlace()
{
    var pending=new Message("local-1","chat","hello","",true,MessageDeliveryState.Sending,DateCreated:1000,IsPending:true,PresentationId:"row-1");
    var row=new MessageRow(pending,MessageEntranceKind.LocalSend);
    var changes=0;
    row.PropertyChanged+=(_,args)=>{if(args.PropertyName==nameof(MessageRow.Value))changes++;};
    True(row.Update(pending with{DeliveryState=MessageDeliveryState.Sent}));
    Equal("row-1",row.PresentationKey);
    Equal(MessageDeliveryState.Sent,row.Value.DeliveryState);
    Equal(1,changes);
    True(!row.Update(row.Value));
    Equal(1,changes);
    True(row.TryConsumeEntrance(out var entrance));
    Equal(MessageEntranceKind.LocalSend,entrance);
    True(!row.TryConsumeEntrance(out entrance));
    Equal(MessageEntranceKind.None,entrance);
}

static void MergeSnapshotRejectsOtherChats()
{
    var previous = new Message("a1", "chat-a", "from A", "", false, MessageDeliveryState.Read, DateCreated: 3000);
    var current = new Message("b1", "chat-b", "from B", "", false, MessageDeliveryState.Read, DateCreated: 2000);
    var pendingFromPrevious = new Message("local-a", "chat-a", "pending A", "", true, MessageDeliveryState.Sending, DateCreated: 4000, IsPending: true);
    var allowed = new HashSet<string>(["chat-b"], StringComparer.OrdinalIgnoreCase);

    var merged = MessageSemantics.MergeSnapshot([previous, pendingFromPrevious], [current], allowed);

    Equal(1, merged.Count);
    Equal("chat-b", merged[0].ChatId);
    Equal("b1", merged[0].Id);
}

static void MergeSnapshotConfirmsPendingOneToOne()
{
    var first = new Message("local-1", "chat", "same", "", true, MessageDeliveryState.Sending, DateCreated: 1000, IsPending: true, PresentationId: "row-1");
    var second = new Message("local-2", "chat", "same", "", true, MessageDeliveryState.Sending, DateCreated: 1001, IsPending: true, PresentationId: "row-2");
    var serverFirst = new Message("server-1", "chat", "same", "", true, MessageDeliveryState.Sent, DateCreated: 1000);
    var serverSecond = new Message("server-2", "chat", "same", "", true, MessageDeliveryState.Sent, DateCreated: 1001);

    var merged = MessageSemantics.MergeSnapshot([first, second], [serverFirst, serverSecond]);

    Equal(2, merged.Count);
    Equal("server-1,server-2", string.Join(',', merged.Select(row=>row.Id)));
    Equal("row-1,row-2", string.Join(',', merged.Select(row=>row.PresentationKey)));
    True(merged.All(row=>!row.IsPending&&row.DeliveryState==MessageDeliveryState.Sent));
}

static void FooterFollowsLatestOptimisticSend()
{
    var first = new Message("local-1", "chat", "one", "", true, MessageDeliveryState.Sending, DateCreated: 1000, IsPending: true, PresentationId: "row-1");
    var second = new Message("local-2", "chat", "two", "", true, MessageDeliveryState.Sending, DateCreated: 1001, IsPending: true, PresentationId: "row-2");
    var sending = ThreadPresentation.Build([first, second], false, "en").Where(row=>!row.IsSeparator).ToArray();
    True(!sending[0].ShowFooter);
    True(sending[1].ShowFooter);
    Equal(MessageDeliveryState.Sending, sending[1].DeliveryState);

    var sentUnconfirmed = second with { DeliveryState = MessageDeliveryState.Sent };
    var awaitingMatch = ThreadPresentation.Build([first, sentUnconfirmed], false, "en").Where(row=>!row.IsSeparator).ToArray();
    True(!awaitingMatch[0].ShowFooter);
    True(awaitingMatch[1].ShowFooter);
    Equal(MessageDeliveryState.Sent, awaitingMatch[1].DeliveryState);
    Equal("row-2", awaitingMatch[1].PresentationKey);
}

static void ParsesLinkPreviewMetadata()
{
    var urls = LinkPreviewSemantics.UrlsInText("See www.example.com/story, now");
    Equal(1, urls.Count);
    Equal("https://www.example.com/story", urls[0]);

    const string html = """
        <html><head>
        <meta content="Example Site" property="og:site_name">
        <meta name="twitter:title" content="A &amp; B">
        <meta property="og:description" content="Preview description">
        <meta content="/images/card.jpg" property="og:image">
        </head></html>
        """;
    var metadata = LinkPreviewSemantics.ParseHtml("https://example.com/posts/1", html);
    Equal("A & B", metadata.Title!);
    Equal("Preview description", metadata.Description!);
    Equal("Example Site", metadata.SiteName!);
    Equal("https://example.com/images/card.jpg", metadata.ImageUrl!);
}

// C74: the release check must never offer a downgrade, and must degrade to
// Unknown (not "up to date", not an update) on drafts or junk payloads.
static void ComparesReleaseVersions()
{
    True(UpdateCheck.IsNewer("v0.65.0", "0.64.0"));
    True(!UpdateCheck.IsNewer("v0.64.0", "0.64.0"));
    True(!UpdateCheck.IsNewer("v0.63.9", "0.64.0"));
    True(!UpdateCheck.IsNewer("v0.64", "0.64.0"));

    var available = UpdateCheck.FromReleaseJson(@"{""tag_name"":""v0.65.0"",""html_url"":""https://example.com/r""}", "0.64.0");
    Equal(UpdateCheckStatus.UpdateAvailable, available.Status);
    Equal("0.65.0", available.LatestVersion!);
    Equal("https://example.com/r", available.ReleaseUrl);

    Equal(UpdateCheckStatus.UpToDate, UpdateCheck.FromReleaseJson(@"{""tag_name"":""v0.64.0""}", "0.64.0").Status);
    Equal(UpdateCheckStatus.Unknown, UpdateCheck.FromReleaseJson(@"{""tag_name"":""v9.9.9"",""draft"":true}", "0.64.0").Status);
    Equal(UpdateCheckStatus.Unknown, UpdateCheck.FromReleaseJson("not json", "0.64.0").Status);
}

static void Equal<T>(T expected, T actual) where T : notnull
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual))
    {
        throw new InvalidOperationException($"Expected {expected}, got {actual}.");
    }
}

static void True(bool condition)
{
    if (!condition)
    {
        throw new InvalidOperationException("Expected condition to be true.");
    }
}

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
    ("attachment preview normalization", NormalizesAttachmentPreviews),
    ("stable chat row notifications", UpdatesChatRowInPlace),
    ("vCard folded and escaped contacts", ParsesVCardContacts),
    ("private and group presentation", PresentsPrivateAndGroupThreads),
    ("reaction and system merging", MergesReactionAndSystemRows),
    ("Twemoji flag-only segmentation", SegmentsOnlyFlagEmoji),
    ("Twemoji Emoji 17 fallback segmentation", SegmentsEmoji17Fallback),
    ("native Windows device registration", BuildsWindowsDeviceRegistration),
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
    var cards=VcfContactImporter.Parse("BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Doe\\, Jane\r\nEMAIL:jane@example.com\r\nTEL;TYPE=CELL:+1 555\r\n 0100\r\nPHOTO;ENCODING=b;TYPE=PNG:AQID\r\n BA==\r\nEND:VCARD\r\n");
    Equal(1,cards.Count);Equal("Doe, Jane",cards[0].DisplayName);Equal("jane@example.com",cards[0].Identities[0]);Equal("+1 5550100",cards[0].Identities[1]);Equal("image/png",cards[0].PhotoMimeType!);Equal(4,cards[0].PhotoBytes!.Length);
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

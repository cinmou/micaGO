using MicaGo.Core.Connection;

var tests = new (string Name, Action Run)[]
{
    ("v1 payload", ParsesV1),
    ("v2 LAN first payload", ParsesV2),
    ("v3 candidate filtering", ParsesV3),
    ("missing token rejection", RejectsMissingToken),
    ("websocket derivation", DerivesWebSocketUrl),
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

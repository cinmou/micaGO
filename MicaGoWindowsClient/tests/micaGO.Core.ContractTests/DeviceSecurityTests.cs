using MicaGo.Core.Connection;
using MicaGo.Infrastructure.Connection;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;

namespace MicaGo.Core.ContractTests;
public static class DeviceSecurityTests
{
    public static void Run()
    {
        using var key=RSA.Create(2048);
        var request=new CertificateRequest("CN=micago",key,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1);
        using var certificate=request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-1),DateTimeOffset.UtcNow.AddDays(1));
        var pin=certificate.GetCertHashString(HashAlgorithmName.SHA256).ToLowerInvariant();
        Require(SecureTransport.ValidateCertificate(certificate,SslPolicyErrors.RemoteCertificateChainErrors,pin),"paired certificate rejected");
        Require(!SecureTransport.ValidateCertificate(certificate,SslPolicyErrors.None,new string('0',64)),"wrong pin accepted even with valid system trust");
        Require(!SecureTransport.ValidateCertificate(certificate,SslPolicyErrors.RemoteCertificateChainErrors,null),"public certificate validation bypassed");
        using var expired=request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-2),DateTimeOffset.UtcNow.AddDays(-1));
        Require(!SecureTransport.ValidateCertificate(expired,SslPolicyErrors.None,expired.GetCertHashString(HashAlgorithmName.SHA256)),"expired pin accepted");
        try {using var client=SecureTransport.CreateClient("http://192.168.1.3:3000");throw new Exception("plaintext allowed");}catch(ConnectionException){}
        var json=JsonSerializer.Serialize(new {version=4,pairingCode=new string('a',64),tlsFingerprint=pin,candidates=new[]{new{kind="lan",baseUrl="https://192.168.1.3:3001",wsUrl="wss://192.168.1.3:3001/ws"}}});
        var payload=PairingPayloadParser.Parse(json);
        Require(payload.PairingCode==new string('a',64)&&payload.Endpoints[0].TlsFingerprint==pin,"v4 invitation or pin lost");
        var profile=new ConnectionProfile("Mac",payload.Endpoints[0].BaseUrl,payload.Endpoints[0].WebSocketUrl,payload.Mode,"old",payload.Endpoints,DeviceId:"device-bound",TlsFingerprint:payload.TlsFingerprint);
        using var update=JsonDocument.Parse("""{"lan":[{"baseUrl":"https://192.168.1.4:3001","wsUrl":"wss://192.168.1.4:3001/ws","hidden":false}],"public":{"enabled":true,"baseUrl":"http://evil.example","wsUrl":"ws://evil.example/ws"}}""");
        var next=EndpointConfiguration.Apply(profile,update.RootElement);
        Require(next.DeviceId==profile.DeviceId&&next.Endpoints.Count==1&&next.Endpoints[0].TlsFingerprint==pin,"refresh downgraded trust or lost identity");
        var publicOnly=profile with {Endpoints=[new ConnectionEndpoint(EndpointKind.Public,"https://relay.example","wss://relay.example/ws")]};
        var discovered=EndpointConfiguration.Apply(publicOnly,update.RootElement);
        Require(discovered.Endpoints.Single().TlsFingerprint==pin,"public-only pairing lost trust when LAN was later advertised");
        try{PairingPayloadParser.Parse(json.Replace("https://192","http://192"));throw new Exception("insecure QR accepted");}catch(PairingPayloadException){}
    }
    private static void Require(bool condition,string message){if(!condition)throw new Exception(message);}
}

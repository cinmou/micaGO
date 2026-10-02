using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace MicaGo.Infrastructure.Connection;

public static class SecureTransport
{
    public static bool ValidateCertificate(X509Certificate? certificate, SslPolicyErrors errors, string? fingerprint)
    {
        if (string.IsNullOrEmpty(fingerprint)) return errors == SslPolicyErrors.None;
        if (certificate is null) return false;
        using var leaf = new X509Certificate2(certificate);
        var now = DateTime.UtcNow;
        return now >= leaf.NotBefore.ToUniversalTime() && now <= leaf.NotAfter.ToUniversalTime()
            && string.Equals(leaf.GetCertHashString(HashAlgorithmName.SHA256), fingerprint, StringComparison.OrdinalIgnoreCase);
    }

    public static HttpClient CreateClient(string baseUrl, string? fingerprint = null)
    {
        if (new Uri(baseUrl).Scheme != "https")
            throw new ConnectionException("This connection requires HTTPS. Create a new pairing code on the Mac.");
        var handler = new HttpClientHandler { AllowAutoRedirect = false };
        handler.ServerCertificateCustomValidationCallback = (_, cert, _, errors) => ValidateCertificate(cert, errors, fingerprint);
        return new HttpClient(handler) { BaseAddress = new Uri(baseUrl.TrimEnd('/') + "/") };
    }
}

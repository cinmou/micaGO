using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using MicaGo.Core.Models;
using MicaGo.Infrastructure.Storage;

namespace MicaGo.Infrastructure.Contacts;

public sealed class GoogleContactsService(LocalCacheStore cache, ISecretStore secrets)
{
    private const string RefreshTokenKey = "google-contacts-refresh-token";
    private readonly HttpClient _http = new();
    public bool IsSignedIn => !string.IsNullOrWhiteSpace(secrets.Read(RefreshTokenKey));

    public async Task SignInAndSyncAsync(string clientId, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(clientId)) throw new InvalidOperationException("A Google OAuth Desktop client ID is required.");
        var verifier = Base64Url(RandomNumberGenerator.GetBytes(48)); var challenge = Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier))); var state = Base64Url(RandomNumberGenerator.GetBytes(24));
        var port = GetFreePort(); var redirect = $"http://127.0.0.1:{port}/"; using var listener = new HttpListener(); listener.Prefixes.Add(redirect); listener.Start();
        var authorize = "https://accounts.google.com/o/oauth2/v2/auth?" + Query(new Dictionary<string,string> { ["client_id"]=clientId,["redirect_uri"]=redirect,["response_type"]="code",["scope"]="https://www.googleapis.com/auth/contacts.readonly",["access_type"]="offline",["prompt"]="consent",["code_challenge"]=challenge,["code_challenge_method"]="S256",["state"]=state });
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(authorize)
        {
            UseShellExecute = true,
        });
        var context = await listener.GetContextAsync().WaitAsync(TimeSpan.FromMinutes(3), cancellationToken); var query=context.Request.QueryString;
        var responseText="You can close this window and return to micaGO."; var bytes=Encoding.UTF8.GetBytes(responseText); context.Response.ContentType="text/plain; charset=utf-8"; await context.Response.OutputStream.WriteAsync(bytes,cancellationToken); context.Response.Close();
        if (query["state"] != state || string.IsNullOrWhiteSpace(query["code"])) throw new InvalidOperationException("Google sign-in was cancelled or returned an invalid state.");
        using var tokenResponse = await _http.PostAsync("https://oauth2.googleapis.com/token", new FormUrlEncodedContent(new Dictionary<string,string>{{"client_id",clientId},{"code",query["code"]!},{"code_verifier",verifier},{"grant_type","authorization_code"},{"redirect_uri",redirect}}), cancellationToken); tokenResponse.EnsureSuccessStatusCode();
        using var tokenJson=JsonDocument.Parse(await tokenResponse.Content.ReadAsStringAsync(cancellationToken)); var access=tokenJson.RootElement.GetProperty("access_token").GetString()!; if(tokenJson.RootElement.TryGetProperty("refresh_token",out var refresh)) secrets.Write(RefreshTokenKey,refresh.GetString()!);
        await cache.SetSettingAsync("google.clientId",clientId,cancellationToken); await SyncWithAccessTokenAsync(access,cancellationToken);
    }

    public async Task SyncAsync(CancellationToken cancellationToken = default)
    {
        var clientId=await cache.GetSettingAsync("google.clientId",cancellationToken); var refresh=secrets.Read(RefreshTokenKey); if(string.IsNullOrWhiteSpace(clientId)||string.IsNullOrWhiteSpace(refresh)) throw new InvalidOperationException("Google Contacts is not signed in.");
        using var response=await _http.PostAsync("https://oauth2.googleapis.com/token",new FormUrlEncodedContent(new Dictionary<string,string>{{"client_id",clientId},{"refresh_token",refresh},{"grant_type","refresh_token"}}),cancellationToken); response.EnsureSuccessStatusCode(); using var json=JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancellationToken)); await SyncWithAccessTokenAsync(json.RootElement.GetProperty("access_token").GetString()!,cancellationToken);
    }

    public async Task SignOutAsync(CancellationToken cancellationToken=default) { secrets.Delete(RefreshTokenKey); await cache.ClearContactsBySourceAsync("google",cancellationToken); }

    private async Task SyncWithAccessTokenAsync(string accessToken,CancellationToken cancellationToken)
    {
        var contacts=new List<ContactMatch>();string? page=null;var syncToken=await cache.GetSettingAsync("google.syncToken",cancellationToken);var incremental=!string.IsNullOrWhiteSpace(syncToken);string? nextSyncToken=null;
        do { var url="https://people.googleapis.com/v1/people/me/connections?pageSize=1000&personFields=names,emailAddresses,phoneNumbers,photos,metadata"+(incremental?"&syncToken="+Uri.EscapeDataString(syncToken!):"&requestSyncToken=true")+(page is null?"":"&pageToken="+Uri.EscapeDataString(page)); using var request=new HttpRequestMessage(HttpMethod.Get,url); request.Headers.Authorization=new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer",accessToken); using var response=await _http.SendAsync(request,cancellationToken);if(response.StatusCode==HttpStatusCode.Gone&&incremental){await cache.SetSettingAsync("google.syncToken","",cancellationToken);await cache.ClearContactsBySourceAsync("google",cancellationToken);await SyncWithAccessTokenAsync(accessToken,cancellationToken);return;} response.EnsureSuccessStatusCode(); using var json=JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancellationToken)); if(json.RootElement.TryGetProperty("connections",out var connections))foreach(var person in connections.EnumerateArray()){if(person.TryGetProperty("metadata",out var metadata)&&metadata.TryGetProperty("deleted",out var deleted)&&deleted.GetBoolean())continue; var name=FirstValue(person,"names","displayName"); if(string.IsNullOrWhiteSpace(name)) continue; var photo=FirstValue(person,"photos","url");var avatar=await DownloadAvatarAsync(photo,accessToken,cancellationToken); foreach(var identity in Values(person,"emailAddresses","value").Concat(Values(person,"phoneNumbers","canonicalForm")).Concat(Values(person,"phoneNumbers","value"))) contacts.Add(new ContactMatch(identity,name,avatar,"google",DateTimeOffset.UtcNow.ToUnixTimeMilliseconds())); } page=json.RootElement.TryGetProperty("nextPageToken",out var next)?next.GetString():null;if(json.RootElement.TryGetProperty("nextSyncToken",out var token))nextSyncToken=token.GetString(); } while(!string.IsNullOrWhiteSpace(page));
        if(!incremental)await cache.ClearContactsBySourceAsync("google",cancellationToken);
        await cache.UpsertContactsAsync(contacts,cancellationToken); await cache.SetSettingAsync("google.lastSync",DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString(),cancellationToken);
        if(!string.IsNullOrWhiteSpace(nextSyncToken))await cache.SetSettingAsync("google.syncToken",nextSyncToken,cancellationToken);
    }
    private async Task<string?> DownloadAvatarAsync(string? url,string accessToken,CancellationToken cancellationToken){if(string.IsNullOrWhiteSpace(url))return null;try{var root=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"micaGO","contact_avatars");Directory.CreateDirectory(root);var path=Path.Combine(root,Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(url))).ToLowerInvariant()+".jpg");if(File.Exists(path))return path;using var request=new HttpRequestMessage(HttpMethod.Get,url);request.Headers.Authorization=new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer",accessToken);using var response=await _http.SendAsync(request,cancellationToken);response.EnsureSuccessStatusCode();var part=path+".part";await File.WriteAllBytesAsync(part,await response.Content.ReadAsByteArrayAsync(cancellationToken),cancellationToken);File.Move(part,path,true);return path;}catch{return null;}}
    private static IEnumerable<string> Values(JsonElement person,string array,string field)=>person.TryGetProperty(array,out var rows)&&rows.ValueKind==JsonValueKind.Array?rows.EnumerateArray().Select(x=>x.TryGetProperty(field,out var v)?v.GetString():null).Where(x=>!string.IsNullOrWhiteSpace(x))!.Cast<string>():[];
    private static string? FirstValue(JsonElement person,string array,string field)=>Values(person,array,field).FirstOrDefault();
    private static string Query(Dictionary<string,string> values)=>string.Join("&",values.Select(x=>$"{Uri.EscapeDataString(x.Key)}={Uri.EscapeDataString(x.Value)}"));
    private static string Base64Url(byte[] value)=>Convert.ToBase64String(value).TrimEnd('=').Replace('+','-').Replace('/','_');
    private static int GetFreePort(){var listener=new System.Net.Sockets.TcpListener(IPAddress.Loopback,0);listener.Start();var port=((IPEndPoint)listener.LocalEndpoint).Port;listener.Stop();return port;}
}

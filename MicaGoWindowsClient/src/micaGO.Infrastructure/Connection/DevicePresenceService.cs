using System.Reflection;
using MicaGo.Core.Connection;
using MicaGo.Core.Models;
using MicaGo.Infrastructure.Contracts;
using MicaGo.Infrastructure.Storage;

namespace MicaGo.Infrastructure.Connection;

/// <summary>
/// Mirrors the Flutter client's device presence lifecycle: register a stable,
/// non-hardware identity after each successful connection and refresh its
/// last-seen timestamp every 30 seconds while the client remains connected.
/// </summary>
public sealed class DevicePresenceService : IDisposable
{
    private static readonly TimeSpan HeartbeatInterval = TimeSpan.FromSeconds(30);
    private readonly ConnectionManager _connection;
    private readonly LocalCacheStore _cache;
    private readonly string _deviceIdPath;
    private CancellationTokenSource? _sessionCancellation;
    private Task? _session;
    private bool _disposed;

    public DevicePresenceService(ConnectionManager connection, LocalCacheStore cache,string? appDataRoot=null)
    {
        _connection=connection;_cache=cache;
        var root=appDataRoot??Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"micaGO");
        _deviceIdPath=Path.Combine(root,"device-id");
        _connection.ConnectionChanged+=Connection_Changed;
        Restart();
    }

    private void Connection_Changed(object? sender,EventArgs e)=>Restart();

    private void Restart()
    {
        _sessionCancellation?.Cancel();_sessionCancellation?.Dispose();_sessionCancellation=null;_session=null;
        if(_disposed||_connection.Api is not{} api||_connection.Profile is not{} profile)return;
        _sessionCancellation=new CancellationTokenSource();
        _session=RunAsync(api,profile,_sessionCancellation.Token);
    }

    private async Task RunAsync(IMicaGoApi api,ConnectionProfile profile,CancellationToken cancellationToken)
    {
        try
        {
            await _cache.InitializeAsync(cancellationToken);
            var id=await EnsureDeviceIdAsync(cancellationToken);
            var registered=false;
            while(!cancellationToken.IsCancellationRequested)
            {
                try
                {
                    if(!registered)
                    {
                        var background=await _cache.GetSettingAsync("settings.tray",cancellationToken)=="true";
                        await api.RegisterDeviceAsync(CreateRegistration(profile,id,background),cancellationToken);
                        registered=true;
                    }
                    else await api.HeartbeatDeviceAsync(id,cancellationToken);
                }
                catch(OperationCanceledException)when(cancellationToken.IsCancellationRequested){break;}
                catch
                {
                    // A failed heartbeat may mean the server restarted and lost
                    // the row. The next pass performs a full registration again.
                    registered=false;
                }
                await Task.Delay(registered?HeartbeatInterval:TimeSpan.FromSeconds(2),cancellationToken);
            }
        }
        catch(OperationCanceledException)when(cancellationToken.IsCancellationRequested){}
        catch
        {
            // Presence is best-effort and must never take down connection startup.
        }
    }

    public static DeviceRegistration CreateRegistration(ConnectionProfile profile,string id,bool background)
    {
        var name=Environment.MachineName.Trim();if(string.IsNullOrWhiteSpace(name))name="micaGO Windows";
        var version=Assembly.GetEntryAssembly()?.GetName().Version?.ToString(3)??Assembly.GetExecutingAssembly().GetName().Version?.ToString(3)??"0.0.0";
        var mode=profile.Endpoints.Any(endpoint=>endpoint.Kind==EndpointKind.Public)?"lan_public":"lan";
        return new DeviceRegistration(id,name,version,"windows",mode,"native","none",false,background);
    }

    private async Task<string> EnsureDeviceIdAsync(CancellationToken cancellationToken)
    {
        if(File.Exists(_deviceIdPath))
        {
            var existing=(await File.ReadAllTextAsync(_deviceIdPath,cancellationToken)).Trim();
            if(!string.IsNullOrWhiteSpace(existing))return existing;
        }
        var created="windows-"+Guid.NewGuid().ToString("N");
        Directory.CreateDirectory(Path.GetDirectoryName(_deviceIdPath)!);
        var temporary=_deviceIdPath+".tmp";
        try{await File.WriteAllTextAsync(temporary,created,cancellationToken);File.Move(temporary,_deviceIdPath,true);}
        finally{if(File.Exists(temporary))File.Delete(temporary);}
        return created;
    }

    public void Dispose()
    {
        if(_disposed)return;_disposed=true;_connection.ConnectionChanged-=Connection_Changed;
        _sessionCancellation?.Cancel();_sessionCancellation?.Dispose();_sessionCancellation=null;_session=null;
    }
}

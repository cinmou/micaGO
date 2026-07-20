using Microsoft.Data.Sqlite;
using MicaGo.Infrastructure.Storage;

internal static class HiddenChatStoreTests
{
    public static async Task RunAsync()
    {
        var path=Path.Combine(Path.GetTempPath(),$"micago-hidden-{Guid.NewGuid():N}.db");
        LocalCacheStore? cache=null;
        try
        {
            cache=new LocalCacheStore(path);await cache.InitializeAsync();
            await cache.HideChatsAsync(["route-a","route-b"]);
            var hidden=await cache.GetHiddenChatGuidsAsync();
            True(hidden.SetEquals(["route-a","route-b"]),"hidden routes were not persisted");
            var restored=await cache.RestoreHiddenChatsAsync(["route-a"]);
            True(restored==1,"selective restore returned the wrong count");
            hidden=await cache.GetHiddenChatGuidsAsync();
            True(hidden.SetEquals(["route-b"]),"selective restore changed the wrong route");
        }
        finally
        {
            cache?.Dispose();SqliteConnection.ClearAllPools();
            foreach(var suffix in new[]{string.Empty,"-wal","-shm"})if(File.Exists(path+suffix))File.Delete(path+suffix);
        }
    }

    private static void True(bool value,string message){if(!value)throw new InvalidOperationException(message);}
}

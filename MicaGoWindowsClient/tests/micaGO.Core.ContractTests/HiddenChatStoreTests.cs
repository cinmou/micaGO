using Microsoft.Data.Sqlite;
using MicaGo.Core.Models;
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
            var message=new Message("message-a","route-b","hello","12:00",false,MessageDeliveryState.Read,DateCreated:1);
            await cache.UpsertMessagesAsync([message]);await cache.HideMessagesAsync([message.Id]);
            True((await cache.GetHiddenMessagesAsync()).Single().Id==message.Id,"hidden message row was not readable");
            True(await cache.RestoreHiddenMessagesAsync([message.Id])==1,"hidden message restore returned the wrong count");
            await cache.SetSettingAsync("settings.language","zh-Hans");await cache.HideChatsAsync(["route-c"]);await cache.ClearContentCacheAsync();
            True(await cache.GetSettingAsync("settings.language")=="zh-Hans","content cache clear removed preferences");
            True((await cache.GetHiddenChatGuidsAsync()).Contains("route-c"),"content cache clear removed hidden state");
        }
        finally
        {
            cache?.Dispose();SqliteConnection.ClearAllPools();
            foreach(var suffix in new[]{string.Empty,"-wal","-shm"})if(File.Exists(path+suffix))File.Delete(path+suffix);
        }
    }

    private static void True(bool value,string message){if(!value)throw new InvalidOperationException(message);}
}

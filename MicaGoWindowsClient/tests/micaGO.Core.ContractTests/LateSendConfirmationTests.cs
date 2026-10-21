using Microsoft.Data.Sqlite;
using MicaGo.Core.Models;
using MicaGo.Infrastructure.Api;
using MicaGo.Infrastructure.Storage;

internal static class LateSendConfirmationTests
{
    public static async Task RunAsync()
    {
        var failed=new Message("local-text","chat","hello","",true,MessageDeliveryState.Failed,DateCreated:100000,IsPending:true);
        var server=new Message("server-text","chat","hello","",true,MessageDeliveryState.Sent,DateCreated:101000);
        Check(MessageSemantics.MatchingPending([failed],server)==failed,"late text confirmation ignored failure");
        var repaired=MessageSemantics.MergeSnapshot([failed,server],[server,server]);
        Check(repaired.Count==1&&!repaired[0].IsPending&&repaired[0].PresentationKey==failed.Id,"old duplicate not repaired");
        var next=failed with{Id="local-next",DeliveryState=MessageDeliveryState.Sending};
        Check(MessageSemantics.MergeSnapshot([repaired[0],next],[server]).Count==2,"duplicate confirmation consumed the next send");
        Check(SendOutcome.FromException(new TimeoutException())==MessageDeliveryState.AwaitingConfirmation,"timeout marked rejected");
        Check(SendOutcome.FromException(new TaskCanceledException())==MessageDeliveryState.AwaitingConfirmation,"HTTP timeout marked failed");
        Check(SendOutcome.FromException(new HttpRequestException())==MessageDeliveryState.AwaitingConfirmation,"transport failure marked rejected");
        Check(SendOutcome.FromException(new MicaGoApiException("accepted",202))==MessageDeliveryState.Sent,"202 lost acceptance");
        var path=Path.Combine(Path.GetTempPath(),$"micago-late-send-{Guid.NewGuid():N}.db");
        try {
            using var cache=new LocalCacheStore(path);
            var upload=new PendingSend("local-upload","chat","/test/photo.jpg","photo.jpg","image/jpeg",100,100000,"failed","timeout");
            await cache.UpsertPendingSendAsync(upload);
            var photo=server with{Id="photo-server",Text="",Attachments=[new Attachment("photo","photo.jpg","image/jpeg",100)]};
            await cache.UpsertMessagesAsync([photo]);
            await cache.UpdatePendingSendAsync(upload with{State="failed"});
            await cache.UpsertPendingSendAsync(upload with{State="sent_unconfirmed"});
            Check((await cache.GetPendingSendsAsync("chat")).Count==0,"late callback resurrected an upload");
            var second=upload with{TempId="local-second"};await cache.UpsertPendingSendAsync(second);
            await cache.UpsertMessagesAsync([photo]);
            Check((await cache.GetPendingSendsAsync("chat")).Count==1,"duplicate server event consumed another upload");
            await cache.UpsertMessagesAsync([photo with{Id="photo-server-2"}]);
            Check((await cache.GetPendingSendsAsync("chat")).Count==0,"second upload did not reconcile");
            var other=upload with{TempId="other-route",ChatId="other"};await cache.UpsertPendingSendAsync(other);
            await cache.UpsertMessagesAsync([photo with{Id="photo-server-3"}]);
            Check((await cache.GetPendingSendsAsync("other")).Count==1,"confirmation crossed routes");
            Check((upload with{State="sending"}).ToMessage().DeliveryState==MessageDeliveryState.AwaitingConfirmation,"interrupted upload restored as active transfer");
        } finally {SqliteConnection.ClearAllPools();foreach(var suffix in new[]{"","-wal","-shm"})if(File.Exists(path+suffix))File.Delete(path+suffix);}
    }
    private static void Check(bool value,string message){if(!value)throw new InvalidOperationException(message);}
}

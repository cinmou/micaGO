using MicaGo.Core.Connection;
using MicaGo.Infrastructure.Storage;

internal static class ConnectionStoreTests
{
    private sealed class Secrets : ISecretStore {
        private string? _value;
        public Action? OnWrite;
        public string? Read(string key)=>_value;
        public void Write(string key,string value) {_value=value;OnWrite?.Invoke();}
        public void Delete(string key)=>_value=null;
    }
    public static async Task RunAsync() {
        var directory=Directory.CreateTempSubdirectory("micago-profile-");
        using var release=new ManualResetEventSlim();
        try {
            var secrets=new Secrets();var store=new ConnectionStore(secrets,directory.FullName);
            var profile=new ConnectionProfile("test","http://lan","ws://lan/ws",ConnectionMode.LanFirst,"r",[new(EndpointKind.Lan,"http://lan","ws://lan/ws")]);
            await store.SaveAsync(profile,"first-test-credential");
            // Cancelled writes must leave both the previous profile and
            // its credential intact.
            var impossible=profile with {ActiveBaseUrl=new string('x',100_000)};
            using var cancellation=new CancellationTokenSource();cancellation.Cancel();
            try {await store.SaveAsync(impossible,"second-test-credential",cancellation.Token);throw new InvalidOperationException("Expected cancellation");}
            catch(OperationCanceledException) { }
            if((await store.LoadAsync())?.Token!="first-test-credential")throw new InvalidOperationException("Cancelled save replaced credential");
            var blockedRoot=Path.Combine(directory.FullName,"blocked");
            Directory.CreateDirectory(Path.Combine(blockedRoot,"connection-profile.json"));
            var blockedStore=new ConnectionStore(secrets,blockedRoot);
            try {await blockedStore.SaveAsync(profile,"second-test-credential");throw new InvalidOperationException("Expected failed profile replacement");}
            catch(IOException) { }
            if((await store.LoadAsync())?.Token!="first-test-credential")throw new InvalidOperationException("Failed profile replacement changed credential");
            var entered=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            secrets.OnWrite=()=>{entered.TrySetResult();if(!release.Wait(TimeSpan.FromSeconds(5)))throw new TimeoutException();};
            var saving=Task.Run(()=>store.SaveAsync(profile,"second-test-credential"));
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(3));
            var clearing=store.ClearAsync();
            if(clearing.IsCompleted)throw new InvalidOperationException("Clear raced with active save");
            release.Set();await saving;await clearing;
            if(await store.LoadAsync() is not null)throw new InvalidOperationException("Save resurrected cleared profile");
        }
        finally {release.Set();directory.Delete(true);}
    }
}

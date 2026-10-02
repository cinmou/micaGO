using MicaGo.Core.Connection;
using MicaGo.Infrastructure.Storage;

internal static class ConnectionStoreTests
{
    private sealed class Secrets : ISecretStore {
        private readonly Dictionary<string,string> _values=[];
        public Action? OnWrite;
        public bool IgnoreWrites;
        public string? Read(string key)=>_values.GetValueOrDefault(key);
        public void Write(string key,string value) {if(!IgnoreWrites)_values[key]=value;OnWrite?.Invoke();}
        public void Delete(string key)=>_values.Remove(key);
    }
    public static async Task RunAsync() {
        var directory=Directory.CreateTempSubdirectory("micago-profile-");
        using var release=new ManualResetEventSlim();
        try {
            var secrets=new Secrets();var store=new ConnectionStore(secrets,directory.FullName);
            var profile=new ConnectionProfile("test","http://lan","ws://lan/ws",ConnectionMode.LanFirst,"r",[new(EndpointKind.Lan,"http://lan","ws://lan/ws")]);
            await store.SaveAsync(profile,"first-test-credential");
            await store.PrepareAsync();
            if((await store.LoadAsync())?.Token!="first-test-credential")throw new Exception("Credential preflight changed the current credential.");
            secrets.IgnoreWrites=true;
            var invitation=System.Text.Json.JsonSerializer.Serialize(new {version=4,pairingCode=new string('a',64),tlsFingerprint=new string('b',64),candidates=new[]{new{kind="lan",baseUrl="https://192.168.1.3:3001",wsUrl="wss://192.168.1.3:3001/ws"}}});
            using(var connection=new MicaGo.Infrastructure.Connection.ConnectionManager(store,new MicaGo.Infrastructure.Connection.EndpointSelector()))
            {
                try {await connection.ConnectPairingJsonAsync(invitation);throw new Exception("Persistence preflight failure reached pairing.");}
                catch(System.ComponentModel.Win32Exception) { }
            }
            secrets.IgnoreWrites=false;
            if((await store.LoadAsync())?.Token!="first-test-credential")throw new Exception("Failed preflight erased an existing credential.");
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

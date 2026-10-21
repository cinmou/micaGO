using MicaGo.Core.Models;
using MicaGo.Infrastructure.Contacts;
using MicaGo.Infrastructure.Storage;

internal static class ContactAccountLinkTests
{
    public static async Task RunAsync()
    {
        var directory = Directory.CreateTempSubdirectory("micago-contact-links-");
        try
        {
            var path = Path.Combine(directory.FullName, "cache.db");
            using (var cache = new LocalCacheStore(path))
            {
                ContactMatch Contact(string address, string id) => new(address, "Same name", null, "vcf", 100, id);
                await cache.UpsertContactsAsync([
                    Contact("one@example.test", "legacy:one"),
                    Contact("+1 (234) 567-8901", "legacy:two"),
                    Contact("other@example.test", "other-person"),
                    Contact("third@example.test", "third-account"),
                ]);
                await cache.LinkContactAccountsAsync("legacy:one", ["legacy:two"]);
                Require((await cache.ResolveContactAsync("+12345678901"))?.ContactId == "legacy:one", "Linked phone and email need the same persistent identity.");
                Require((await cache.ResolveContactAsync("other@example.test"))?.ContactId == "other-person", "Identical names must not merge without an explicit selection.");
                Require(await cache.GetSettingAsync("chat.mergeRoutes.legacy:one") == "1", "Linking must enable the merged conversation.");
                await cache.UpsertContactsAsync([Contact("+12345678901", "legacy:two")]);
                Require((await cache.ResolveContactAsync("+12345678901"))?.ContactId == "legacy:one", "Reimport must preserve explicit account links.");
                await cache.UpsertContactsAsync([Contact("new@example.test", "vcf:new-uid"), Contact("+12345678901", "vcf:new-uid")]);
                Require((await cache.ResolveContactAsync("new@example.test"))?.ContactId == "legacy:one", "A later vCard UID must keep the legacy user link for all its addresses.");
                await cache.LinkContactAccountsAsync("third-account", ["legacy:one"]);
                await cache.UpsertContactsAsync([Contact("+12345678901", "legacy:two")]);
                Require((await cache.ResolveContactAsync("+12345678901"))?.ContactId == "third-account", "Linking an already linked contact must flatten aliases.");
            }
            using (var reopened = new LocalCacheStore(path))
            {
                Require((await reopened.ResolveContactAsync("one@example.test"))?.ContactId == "third-account", "Links must survive reopening the cache.");
                using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
                try { await reopened.LinkContactAccountsAsync("other-person", ["third-account"], cancelled.Token); throw new Exception("Expected cancellation"); }
                catch (OperationCanceledException) { }
                Require((await reopened.ResolveContactAsync("one@example.test"))?.ContactId == "third-account", "Cancelled linking must not partially change identity.");
                await reopened.ClearImportedContactsAsync();
                await reopened.UpsertContactsAsync([new("+12345678901", "Reimport", null, "vcf", 101, "legacy:two")]);
                Require((await reopened.ResolveContactAsync("+12345678901"))?.ContactId == "legacy:two", "Clearing imported contacts must also clear old links.");
                var vcfPath = Path.Combine(directory.FullName, "overlap.vcf");
                await File.WriteAllTextAsync(vcfPath, "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Sample\r\nEMAIL:pending@example.test\r\nEND:VCARD\r\nBEGIN:VCARD\r\nVERSION:3.0\r\nFN:Sample\r\nEMAIL:PENDING@example.test\r\nTEL:+19995551234\r\nEND:VCARD\r\n");
                await new VcfContactImporter(reopened).ImportAsync(vcfPath);
                Require((await reopened.ResolveContactAsync("pending@example.test"))?.ContactId == (await reopened.ResolveContactAsync("+19995551234"))?.ContactId,
                    "Overlapping UID-less cards in one import must share identity.");
            }
        }
        finally { Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools(); directory.Delete(true); }
    }

    private static void Require(bool condition, string message) { if (!condition) throw new Exception(message); }
}

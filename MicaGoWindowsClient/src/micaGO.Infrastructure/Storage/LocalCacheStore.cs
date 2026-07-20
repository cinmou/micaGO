using System.Text.Json;
using Microsoft.Data.Sqlite;
using MicaGo.Core.Models;

namespace MicaGo.Infrastructure.Storage;

public sealed class LocalCacheStore : IDisposable
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly string _connectionString;
    private bool _initialized;

    public LocalCacheStore(string? databasePath = null)
    {
        var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "micaGO");
        Directory.CreateDirectory(root);
        DatabasePath = databasePath ?? Path.Combine(root, "cache.db");
        _connectionString = new SqliteConnectionStringBuilder { DataSource = DatabasePath, Mode = SqliteOpenMode.ReadWriteCreate }.ToString();
    }

    public string DatabasePath { get; }

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            if (_initialized) return;
            await using var db = new SqliteConnection(_connectionString);
            await db.OpenAsync(cancellationToken);
            await ExecuteAsync(db, """
                PRAGMA journal_mode=WAL;
                PRAGMA foreign_keys=ON;
                CREATE TABLE IF NOT EXISTS chats (
                    guid TEXT PRIMARY KEY,
                    updated_at INTEGER NOT NULL,
                    json TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS messages (
                    guid TEXT PRIMARY KEY,
                    chat_guid TEXT NOT NULL,
                    date_created INTEGER NOT NULL,
                    json TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_messages_chat_date ON messages(chat_guid, date_created DESC);
                CREATE TABLE IF NOT EXISTS settings (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS contacts (
                    identity TEXT PRIMARY KEY,
                    display_name TEXT NOT NULL,
                    avatar_path TEXT,
                    source TEXT NOT NULL,
                    updated_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS hidden_messages (
                    guid TEXT PRIMARY KEY,
                    hidden_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS hidden_chats (
                    guid TEXT PRIMARY KEY,
                    hidden_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS pending_uploads (
                    temp_id TEXT PRIMARY KEY,
                    chat_guid TEXT NOT NULL,
                    date_created INTEGER NOT NULL,
                    json TEXT NOT NULL
                );
                """, cancellationToken);
            _initialized = true;
        }
        finally { _gate.Release(); }
    }

    public async Task UpsertChatsAsync(IEnumerable<ChatSummary> chats, CancellationToken cancellationToken = default)
    {
        await EnsureInitializedAsync(cancellationToken);
        await _gate.WaitAsync(cancellationToken);
        try
        {
            await using var db = new SqliteConnection(_connectionString); await db.OpenAsync(cancellationToken);
            await using var transaction = db.BeginTransaction();
            foreach (var chat in chats)
            {
                await using var cmd = db.CreateCommand(); cmd.Transaction = transaction;
                cmd.CommandText = "INSERT INTO chats(guid, updated_at, json) VALUES($id,$at,$json) ON CONFLICT(guid) DO UPDATE SET updated_at=excluded.updated_at,json=excluded.json";
                cmd.Parameters.AddWithValue("$id", chat.Id); cmd.Parameters.AddWithValue("$at", chat.UpdatedAt); cmd.Parameters.AddWithValue("$json", JsonSerializer.Serialize(chat));
                await cmd.ExecuteNonQueryAsync(cancellationToken);
            }
            await transaction.CommitAsync(cancellationToken);
        }
        finally { _gate.Release(); }
    }

    public async Task UpsertMessagesAsync(IEnumerable<Message> messages, CancellationToken cancellationToken = default)
    {
        await EnsureInitializedAsync(cancellationToken);
        await _gate.WaitAsync(cancellationToken);
        try
        {
            await using var db = new SqliteConnection(_connectionString); await db.OpenAsync(cancellationToken);
            await using var transaction = db.BeginTransaction();
            foreach (var message in messages.Where(item => !item.IsPending))
            {
                await using var cmd = db.CreateCommand(); cmd.Transaction = transaction;
                cmd.CommandText = "INSERT INTO messages(guid,chat_guid,date_created,json) VALUES($id,$chat,$at,$json) ON CONFLICT(guid) DO UPDATE SET chat_guid=excluded.chat_guid,date_created=excluded.date_created,json=excluded.json";
                cmd.Parameters.AddWithValue("$id", message.Id); cmd.Parameters.AddWithValue("$chat", message.ChatId); cmd.Parameters.AddWithValue("$at", message.DateCreated); cmd.Parameters.AddWithValue("$json", JsonSerializer.Serialize(message));
                await cmd.ExecuteNonQueryAsync(cancellationToken);
            }
            await transaction.CommitAsync(cancellationToken);
        }
        finally { _gate.Release(); }
    }

    public async Task<IReadOnlyList<ChatSummary>> GetChatsAsync(CancellationToken cancellationToken = default) =>
        await ReadJsonRowsAsync<ChatSummary>("SELECT json FROM chats ORDER BY updated_at DESC", cancellationToken);

    public async Task<IReadOnlyList<Message>> GetMessagesAsync(string chatId, int limit = 100, int offset = 0, CancellationToken cancellationToken = default)
    {
        await EnsureInitializedAsync(cancellationToken);
        await _gate.WaitAsync(cancellationToken);
        try
        {
            await using var db = new SqliteConnection(_connectionString); await db.OpenAsync(cancellationToken);
            await using var cmd = db.CreateCommand();
            cmd.CommandText = "SELECT json FROM messages WHERE chat_guid=$chat ORDER BY date_created DESC LIMIT $limit OFFSET $offset";
            cmd.Parameters.AddWithValue("$chat", chatId); cmd.Parameters.AddWithValue("$limit", limit); cmd.Parameters.AddWithValue("$offset", offset);
            var rows = new List<Message>(); await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken)) { var item = JsonSerializer.Deserialize<Message>(reader.GetString(0)); if (item is not null) rows.Add(item); }
            rows.Reverse(); return rows;
        }
        finally { _gate.Release(); }
    }

    public async Task<string?> GetSettingAsync(string key, CancellationToken cancellationToken = default)
    {
        await EnsureInitializedAsync(cancellationToken); await _gate.WaitAsync(cancellationToken);
        try { await using var db = new SqliteConnection(_connectionString); await db.OpenAsync(cancellationToken); await using var cmd = db.CreateCommand(); cmd.CommandText = "SELECT value FROM settings WHERE key=$key"; cmd.Parameters.AddWithValue("$key", key); return await cmd.ExecuteScalarAsync(cancellationToken) as string; }
        finally { _gate.Release(); }
    }

    public async Task SetSettingAsync(string key, string value, CancellationToken cancellationToken = default)
    {
        await EnsureInitializedAsync(cancellationToken); await _gate.WaitAsync(cancellationToken);
        try { await using var db = new SqliteConnection(_connectionString); await db.OpenAsync(cancellationToken); await using var cmd = db.CreateCommand(); cmd.CommandText = "INSERT INTO settings(key,value) VALUES($key,$value) ON CONFLICT(key) DO UPDATE SET value=excluded.value"; cmd.Parameters.AddWithValue("$key", key); cmd.Parameters.AddWithValue("$value", value); await cmd.ExecuteNonQueryAsync(cancellationToken); }
        finally { _gate.Release(); }
    }

    public async Task DeleteMessageAsync(string guid, CancellationToken cancellationToken = default)
    {
        await EnsureInitializedAsync(cancellationToken); await _gate.WaitAsync(cancellationToken);
        try { await using var db = new SqliteConnection(_connectionString); await db.OpenAsync(cancellationToken); await using var cmd = db.CreateCommand(); cmd.CommandText = "DELETE FROM messages WHERE guid=$id"; cmd.Parameters.AddWithValue("$id", guid); await cmd.ExecuteNonQueryAsync(cancellationToken); }
        finally { _gate.Release(); }
    }

    public async Task UpsertPendingUploadAsync(PendingUpload upload,CancellationToken cancellationToken=default)
    {
        await EnsureInitializedAsync(cancellationToken);await _gate.WaitAsync(cancellationToken);try{await using var db=new SqliteConnection(_connectionString);await db.OpenAsync(cancellationToken);await using var cmd=db.CreateCommand();cmd.CommandText="INSERT INTO pending_uploads(temp_id,chat_guid,date_created,json) VALUES($id,$chat,$at,$json) ON CONFLICT(temp_id) DO UPDATE SET json=excluded.json,date_created=excluded.date_created";cmd.Parameters.AddWithValue("$id",upload.TempId);cmd.Parameters.AddWithValue("$chat",upload.ChatId);cmd.Parameters.AddWithValue("$at",upload.DateCreated);cmd.Parameters.AddWithValue("$json",JsonSerializer.Serialize(upload));await cmd.ExecuteNonQueryAsync(cancellationToken);}finally{_gate.Release();}
    }
    public async Task<IReadOnlyList<PendingUpload>> GetPendingUploadsAsync(string chatId,CancellationToken cancellationToken=default)
    {
        await EnsureInitializedAsync(cancellationToken);await _gate.WaitAsync(cancellationToken);try{await using var db=new SqliteConnection(_connectionString);await db.OpenAsync(cancellationToken);await using var cmd=db.CreateCommand();cmd.CommandText="SELECT json FROM pending_uploads WHERE chat_guid=$chat ORDER BY date_created";cmd.Parameters.AddWithValue("$chat",chatId);var rows=new List<PendingUpload>();await using var reader=await cmd.ExecuteReaderAsync(cancellationToken);while(await reader.ReadAsync(cancellationToken)){var row=JsonSerializer.Deserialize<PendingUpload>(reader.GetString(0));if(row is not null)rows.Add(row);}return rows;}finally{_gate.Release();}
    }
    public async Task DeletePendingUploadAsync(string tempId,CancellationToken cancellationToken=default)
    {
        await EnsureInitializedAsync(cancellationToken);await _gate.WaitAsync(cancellationToken);try{await using var db=new SqliteConnection(_connectionString);await db.OpenAsync(cancellationToken);await using var cmd=db.CreateCommand();cmd.CommandText="DELETE FROM pending_uploads WHERE temp_id=$id";cmd.Parameters.AddWithValue("$id",tempId);await cmd.ExecuteNonQueryAsync(cancellationToken);}finally{_gate.Release();}
    }

    public async Task HideMessagesAsync(IEnumerable<string> guids, CancellationToken cancellationToken = default)
    {
        await EnsureInitializedAsync(cancellationToken); await _gate.WaitAsync(cancellationToken);
        try
        {
            await using var db = new SqliteConnection(_connectionString); await db.OpenAsync(cancellationToken);
            await using var tx = db.BeginTransaction();
            var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            foreach (var guid in guids.Where(value => !string.IsNullOrWhiteSpace(value)))
            {
                await using var cmd = db.CreateCommand(); cmd.Transaction = tx;
                cmd.CommandText = "INSERT INTO hidden_messages(guid,hidden_at) VALUES($id,$at) ON CONFLICT(guid) DO NOTHING";
                cmd.Parameters.AddWithValue("$id", guid); cmd.Parameters.AddWithValue("$at", now);
                await cmd.ExecuteNonQueryAsync(cancellationToken);
            }
            await tx.CommitAsync(cancellationToken);
        }
        finally { _gate.Release(); }
    }

    public async Task<IReadOnlySet<string>> GetHiddenMessageGuidsAsync(CancellationToken cancellationToken = default)
    {
        await EnsureInitializedAsync(cancellationToken); await _gate.WaitAsync(cancellationToken);
        try
        {
            await using var db = new SqliteConnection(_connectionString); await db.OpenAsync(cancellationToken);
            await using var cmd = db.CreateCommand(); cmd.CommandText = "SELECT guid FROM hidden_messages";
            var rows = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken)) rows.Add(reader.GetString(0));
            return rows;
        }
        finally { _gate.Release(); }
    }

    public async Task HideChatsAsync(IEnumerable<string> guids, CancellationToken cancellationToken = default)
    {
        await EnsureInitializedAsync(cancellationToken); await _gate.WaitAsync(cancellationToken);
        try
        {
            await using var db = new SqliteConnection(_connectionString); await db.OpenAsync(cancellationToken);
            await using var tx = db.BeginTransaction();
            var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            foreach (var guid in guids.Where(value => !string.IsNullOrWhiteSpace(value)))
            {
                await using var cmd = db.CreateCommand(); cmd.Transaction = tx;
                cmd.CommandText = "INSERT INTO hidden_chats(guid,hidden_at) VALUES($id,$at) ON CONFLICT(guid) DO NOTHING";
                cmd.Parameters.AddWithValue("$id", guid); cmd.Parameters.AddWithValue("$at", now);
                await cmd.ExecuteNonQueryAsync(cancellationToken);
            }
            await tx.CommitAsync(cancellationToken);
        }
        finally { _gate.Release(); }
    }

    public async Task<int> RestoreHiddenChatsAsync(IEnumerable<string> guids,CancellationToken cancellationToken=default)
    {
        var ids=guids.Where(value=>!string.IsNullOrWhiteSpace(value)).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        if(ids.Length==0)return 0;
        await EnsureInitializedAsync(cancellationToken);await _gate.WaitAsync(cancellationToken);
        try
        {
            await using var db=new SqliteConnection(_connectionString);await db.OpenAsync(cancellationToken);await using var tx=db.BeginTransaction();var restored=0;
            foreach(var guid in ids)
            {
                await using var cmd=db.CreateCommand();cmd.Transaction=tx;cmd.CommandText="DELETE FROM hidden_chats WHERE guid=$id";cmd.Parameters.AddWithValue("$id",guid);restored+=await cmd.ExecuteNonQueryAsync(cancellationToken);
            }
            await tx.CommitAsync(cancellationToken);return restored;
        }
        finally{_gate.Release();}
    }

    public async Task<IReadOnlySet<string>> GetHiddenChatGuidsAsync(CancellationToken cancellationToken = default)
    {
        await EnsureInitializedAsync(cancellationToken); await _gate.WaitAsync(cancellationToken);
        try
        {
            await using var db = new SqliteConnection(_connectionString); await db.OpenAsync(cancellationToken);
            await using var cmd = db.CreateCommand(); cmd.CommandText = "SELECT guid FROM hidden_chats";
            var rows = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken)) rows.Add(reader.GetString(0));
            return rows;
        }
        finally { _gate.Release(); }
    }

    public async Task<IReadOnlyDictionary<string, string>> GetAllSettingsAsync(CancellationToken cancellationToken = default)
    {
        await EnsureInitializedAsync(cancellationToken); await _gate.WaitAsync(cancellationToken);
        try
        {
            await using var db = new SqliteConnection(_connectionString); await db.OpenAsync(cancellationToken);
            await using var cmd = db.CreateCommand(); cmd.CommandText = "SELECT key,value FROM settings";
            var rows = new Dictionary<string, string>();
            await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken)) rows[reader.GetString(0)] = reader.GetString(1);
            return rows;
        }
        finally { _gate.Release(); }
    }

    public async Task UpsertContactsAsync(IEnumerable<ContactMatch> contacts, CancellationToken cancellationToken = default)
    {
        await EnsureInitializedAsync(cancellationToken); await _gate.WaitAsync(cancellationToken);
        try
        {
            await using var db = new SqliteConnection(_connectionString); await db.OpenAsync(cancellationToken); await using var tx = db.BeginTransaction();
            foreach (var contact in contacts)
            {
                await using var cmd = db.CreateCommand(); cmd.Transaction = tx; cmd.CommandText = "INSERT INTO contacts(identity,display_name,avatar_path,source,updated_at) VALUES($id,$name,$avatar,$source,$at) ON CONFLICT(identity) DO UPDATE SET display_name=excluded.display_name,avatar_path=excluded.avatar_path,source=excluded.source,updated_at=excluded.updated_at";
                cmd.Parameters.AddWithValue("$id", NormalizeIdentity(contact.Identity)); cmd.Parameters.AddWithValue("$name", contact.DisplayName); cmd.Parameters.AddWithValue("$avatar", (object?)contact.AvatarPath ?? DBNull.Value); cmd.Parameters.AddWithValue("$source", contact.Source); cmd.Parameters.AddWithValue("$at", contact.UpdatedAt); await cmd.ExecuteNonQueryAsync(cancellationToken);
            }
            await tx.CommitAsync(cancellationToken);
        }
        finally { _gate.Release(); }
    }

    public async Task<ContactMatch?> ResolveContactAsync(string identity, CancellationToken cancellationToken = default)
    {
        await EnsureInitializedAsync(cancellationToken); await _gate.WaitAsync(cancellationToken);
        try { await using var db = new SqliteConnection(_connectionString); await db.OpenAsync(cancellationToken); await using var cmd = db.CreateCommand(); cmd.CommandText="SELECT display_name,avatar_path,source,updated_at FROM contacts WHERE identity=$id"; cmd.Parameters.AddWithValue("$id", NormalizeIdentity(identity)); await using var row=await cmd.ExecuteReaderAsync(cancellationToken); return await row.ReadAsync(cancellationToken) ? new ContactMatch(identity,row.GetString(0),row.IsDBNull(1)?null:row.GetString(1),row.GetString(2),row.GetInt64(3)) : null; }
        finally { _gate.Release(); }
    }

    public async Task ClearContactsBySourceAsync(string source,CancellationToken cancellationToken=default)
    {
        await EnsureInitializedAsync(cancellationToken);await _gate.WaitAsync(cancellationToken);
        try{await using var db=new SqliteConnection(_connectionString);await db.OpenAsync(cancellationToken);await using var cmd=db.CreateCommand();cmd.CommandText="DELETE FROM contacts WHERE source=$source";cmd.Parameters.AddWithValue("$source",source);await cmd.ExecuteNonQueryAsync(cancellationToken);}
        finally{_gate.Release();}
    }

    public async Task ClearImportedContactsAsync(CancellationToken cancellationToken=default)
    {
        await EnsureInitializedAsync(cancellationToken);await _gate.WaitAsync(cancellationToken);
        try{await using var db=new SqliteConnection(_connectionString);await db.OpenAsync(cancellationToken);await using var cmd=db.CreateCommand();cmd.CommandText="DELETE FROM contacts WHERE source='vcf' OR source='csv' OR source LIKE 'vcf:%'";await cmd.ExecuteNonQueryAsync(cancellationToken);}
        finally{_gate.Release();}
    }

    public async Task ClearAsync(CancellationToken cancellationToken = default)
    {
        await EnsureInitializedAsync(cancellationToken); await _gate.WaitAsync(cancellationToken);
        try { await using var db = new SqliteConnection(_connectionString); await db.OpenAsync(cancellationToken); await ExecuteAsync(db, "DELETE FROM messages; DELETE FROM chats; DELETE FROM settings; DELETE FROM contacts; DELETE FROM hidden_messages; DELETE FROM hidden_chats; DELETE FROM pending_uploads;", cancellationToken); }
        finally { _gate.Release(); }
    }

    private async Task<IReadOnlyList<T>> ReadJsonRowsAsync<T>(string sql, CancellationToken cancellationToken)
    {
        await EnsureInitializedAsync(cancellationToken); await _gate.WaitAsync(cancellationToken);
        try { await using var db = new SqliteConnection(_connectionString); await db.OpenAsync(cancellationToken); await using var cmd = db.CreateCommand(); cmd.CommandText = sql; var rows = new List<T>(); await using var reader = await cmd.ExecuteReaderAsync(cancellationToken); while (await reader.ReadAsync(cancellationToken)) { var item = JsonSerializer.Deserialize<T>(reader.GetString(0)); if (item is not null) rows.Add(item); } return rows; }
        finally { _gate.Release(); }
    }

    private async Task EnsureInitializedAsync(CancellationToken cancellationToken) { if (!_initialized) await InitializeAsync(cancellationToken); }
    private static string NormalizeIdentity(string value) { var text=value.Trim().ToLowerInvariant(); if(text.Contains('@')) return text; var digits=new string(text.Where(char.IsDigit).ToArray()); return digits.Length == 0 ? text : "+" + digits; }
    private static async Task ExecuteAsync(SqliteConnection db, string sql, CancellationToken cancellationToken) { await using var cmd = db.CreateCommand(); cmd.CommandText = sql; await cmd.ExecuteNonQueryAsync(cancellationToken); }
    public void Dispose() => _gate.Dispose();
}

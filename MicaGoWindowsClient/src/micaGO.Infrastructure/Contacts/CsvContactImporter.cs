using System.Text;
using MicaGo.Core.Models;
using MicaGo.Infrastructure.Storage;

namespace MicaGo.Infrastructure.Contacts;

public sealed record CsvContactImportResult(int ContactCount, int IdentityCount, int SkippedRows);

public sealed class CsvContactImporter(LocalCacheStore cache)
{
    public async Task<CsvContactImportResult> ImportAsync(string path, CancellationToken cancellationToken = default)
    {
        await using var stream = File.OpenRead(path);
        using var reader = new StreamReader(stream, Encoding.UTF8, true);
        var rows = Parse(await reader.ReadToEndAsync(cancellationToken));
        if (rows.Count == 0) throw new InvalidDataException("The CSV file is empty.");

        var headers = rows[0].Select(NormalizeHeader).ToArray();
        var nameColumns = FindColumns(headers, "name", "fullname", "displayname", "formattedname");
        var givenColumns = FindColumns(headers, "givenname", "firstname");
        var middleColumns = FindColumns(headers, "additionalname", "middlename");
        var familyColumns = FindColumns(headers, "familyname", "lastname", "surname");
        var identityColumns = headers.Select((header, index) => (header, index))
            .Where(item => item.header.Contains("email", StringComparison.Ordinal) || item.header.Contains("phone", StringComparison.Ordinal) || item.header is "mobile" or "telephone")
            .Select(item => item.index).ToArray();
        if (identityColumns.Length == 0) throw new InvalidDataException("No email or phone columns were found.");

        var contacts = new Dictionary<string, ContactMatch>(StringComparer.OrdinalIgnoreCase);
        var people = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var skipped = 0;
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        foreach (var row in rows.Skip(1))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var identities = identityColumns.SelectMany(column => Values(Cell(row, column))).Where(IsUsableIdentity).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
            if (identities.Length == 0) { skipped++; continue; }
            var displayName = FirstValue(row, nameColumns);
            if (string.IsNullOrWhiteSpace(displayName))
                displayName = string.Join(" ", new[] { FirstValue(row, givenColumns), FirstValue(row, middleColumns), FirstValue(row, familyColumns) }.Where(value => !string.IsNullOrWhiteSpace(value)));
            if (string.IsNullOrWhiteSpace(displayName)) displayName = identities[0];
            displayName = displayName.Trim();
            people.Add(displayName);
            foreach (var identity in identities) contacts[identity] = new ContactMatch(identity, displayName, null, "csv", now);
        }
        await cache.UpsertContactsAsync(contacts.Values, cancellationToken);
        await cache.SetSettingAsync("contacts.csv.lastImport", now.ToString(), cancellationToken);
        return new CsvContactImportResult(people.Count, contacts.Count, skipped);
    }

    public static IReadOnlyList<IReadOnlyList<string>> Parse(string text)
    {
        var rows = new List<IReadOnlyList<string>>(); var row = new List<string>(); var field = new StringBuilder(); var quoted = false;
        for (var i = 0; i < text.Length; i++)
        {
            var ch = text[i];
            if (quoted)
            {
                if (ch == '"' && i + 1 < text.Length && text[i + 1] == '"') { field.Append('"'); i++; }
                else if (ch == '"') quoted = false;
                else field.Append(ch);
                continue;
            }
            if (ch == '"' && field.Length == 0) quoted = true;
            else if (ch == ',') { row.Add(field.ToString()); field.Clear(); }
            else if (ch is '\r' or '\n')
            {
                if (ch == '\r' && i + 1 < text.Length && text[i + 1] == '\n') i++;
                row.Add(field.ToString()); field.Clear();
                if (row.Any(value => value.Length > 0)) rows.Add(row);
                row = [];
            }
            else field.Append(ch);
        }
        if (field.Length > 0 || row.Count > 0) { row.Add(field.ToString()); if (row.Any(value => value.Length > 0)) rows.Add(row); }
        return rows;
    }

    private static string NormalizeHeader(string value) => new(value.Trim().TrimStart('\uFEFF').ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray());
    private static int[] FindColumns(string[] headers, params string[] names) => headers.Select((header, index) => (header, index)).Where(item => names.Contains(item.header, StringComparer.Ordinal)).Select(item => item.index).ToArray();
    private static string Cell(IReadOnlyList<string> row, int column) => column < row.Count ? row[column].Trim() : string.Empty;
    private static string FirstValue(IReadOnlyList<string> row, IEnumerable<int> columns) => columns.Select(column => Cell(row, column)).FirstOrDefault(value => !string.IsNullOrWhiteSpace(value)) ?? string.Empty;
    private static IEnumerable<string> Values(string value) => value.Split([" ::: ", ";"], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
    private static bool IsUsableIdentity(string value) => value.Contains('@') || value.Count(char.IsDigit) >= 5;
}

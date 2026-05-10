using Microsoft.Data.Sqlite;

namespace UsageMeter.Core;

public sealed class SqliteReader(WindowsPaths paths)
{
    public IReadOnlyList<Dictionary<string, object?>> Query(string dbPath, string sql)
    {
        var expanded = paths.Expand(dbPath);
        if (!File.Exists(expanded))
        {
            return [];
        }

        var builder = new SqliteConnectionStringBuilder
        {
            DataSource = expanded,
            Mode = SqliteOpenMode.ReadOnly,
            Cache = SqliteCacheMode.Shared
        };

        using var connection = new SqliteConnection(builder.ToString());
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        using var reader = command.ExecuteReader();

        var rows = new List<Dictionary<string, object?>>();
        while (reader.Read())
        {
            var row = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
            for (var i = 0; i < reader.FieldCount; i++)
            {
                row[reader.GetName(i)] = reader.IsDBNull(i) ? null : reader.GetValue(i);
            }
            rows.Add(row);
        }

        return rows;
    }

    public string? ReadStateValue(string dbPath, string key)
    {
        var escaped = key.Replace("'", "''", StringComparison.Ordinal);
        var rows = Query(dbPath, $"SELECT value FROM ItemTable WHERE key = '{escaped}' LIMIT 1");
        return rows.Count > 0 ? Convert.ToString(rows[0].GetValueOrDefault("value")) : null;
    }
}

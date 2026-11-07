using System.Data.Common;
using System.Globalization;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using Microsoft.Data.Sqlite;
using MySqlConnector;

var connectionString = Environment.GetEnvironmentVariable("GRATE_POC_CHECK_CONNECTION")
    ?? throw new InvalidOperationException("GRATE_POC_CHECK_CONNECTION is required.");

await using DbConnection connection = args.Single() switch
{
    "SQLite" => new SqliteConnection(connectionString),
    "SQLServer" => new SqlConnection(connectionString),
    "MariaDB" => new MySqlConnection(connectionString),
    _ => throw new ArgumentException("Unknown verification provider.")
};
await connection.OpenAsync();

var prefix = args[0] == "SQLServer" ? "grate." : "grate_";
var data = await ReadRows("SELECT id, name FROM widgets ORDER BY id");
var history = await ReadRows($"SELECT script_name, text_hash FROM {prefix}ScriptsRun ORDER BY id");
var errors = await ReadRows($"SELECT COUNT(*) FROM {prefix}ScriptsRunErrors");
Console.WriteLine(JsonSerializer.Serialize(new { data, history, errors }));

async Task<List<string[]>> ReadRows(string sql)
{
    await using var command = connection.CreateCommand();
    command.CommandText = sql;
    await using var reader = await command.ExecuteReaderAsync();
    var rows = new List<string[]>();
    while (await reader.ReadAsync())
    {
        var values = new string[reader.FieldCount];
        for (var index = 0; index < values.Length; index++)
        {
            values[index] = Convert.ToString(reader.GetValue(index), CultureInfo.InvariantCulture) ?? "";
        }
        rows.Add(values);
    }
    return rows;
}

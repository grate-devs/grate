using System.Text.Json;
using Dapper;
using MySqlConnector;

var password = Environment.GetEnvironmentVariable("GRATE_PROBE_PASSWORD")
    ?? throw new InvalidOperationException("The disposable database password is required.");
await using var connection = new MySqlConnection(new MySqlConnectionStringBuilder
{
    Server = "db",
    Database = "source_probe",
    UserID = "source_probe",
    Password = password,
    ConnectionTimeout = 5,
    SslMode = MySqlSslMode.Disabled
}.ConnectionString);
await connection.OpenAsync();
await connection.ExecuteAsync("CREATE TABLE probe (id INT PRIMARY KEY, name VARCHAR(100) NOT NULL, amount DECIMAL(12,2) NOT NULL) CHARACTER SET utf8mb4");
var inserted = await connection.ExecuteAsync(
    "INSERT INTO probe (id, name, amount) VALUES (@Id, @Name, @Amount)",
    new { Id = 7, Name = "Trøndelag ' & <", Amount = 123.45m });
if (inserted != 1)
{
    throw new InvalidOperationException("The parameterized insert must affect exactly one row.");
}
var row = await connection.QuerySingleAsync<ProbeRow>("SELECT id AS Id, name AS Name, amount AS Amount FROM probe WHERE id=@Id", new { Id = 7 });
if (row.Id != 7 || row.Name != "Trøndelag ' & <" || row.Amount != 123.45m)
{
    throw new InvalidOperationException("Typed mapping must preserve the independently specified values.");
}
await using (var transaction = await connection.BeginTransactionAsync())
{
    await connection.ExecuteAsync("INSERT INTO probe (id, name, amount) VALUES (8, 'rolled back', 9.99)", transaction: transaction);
    await transaction.RollbackAsync();
}
var rollbackRows = await connection.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM probe WHERE id=8");
if (rollbackRows != 0)
{
    throw new InvalidOperationException("A rolled-back insert must not remain in the database.");
}
var dapper = typeof(SqlMapper).Assembly.GetName();
var mysql = typeof(MySqlConnection).Assembly.GetName();
if (dapper.Version?.ToString() != "2.0.0.0" || dapper.GetPublicKeyToken()?.Length != 0
    || mysql.Version?.ToString() != "2.0.0.0"
    || Convert.ToHexString(mysql.GetPublicKeyToken() ?? []).ToLowerInvariant() != "d33d3e53aa5f8c92")
{
    throw new InvalidOperationException("The source-built assemblies must preserve their public assembly identities.");
}
Console.WriteLine(JsonSerializer.Serialize(new { status = "SOURCE_BUILD_PROBE_OK", row, rollbackRows, dapper = dapper.FullName, mysql = mysql.FullName }));

internal sealed class ProbeRow
{
    public int Id { get; set; }
    public string Name { get; set; } = "";
    public decimal Amount { get; set; }
}

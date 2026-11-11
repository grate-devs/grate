using System.Data.Common;
using Microsoft.Data.SqlClient;
using Microsoft.Data.Sqlite;
using Npgsql;

var builder = WebApplication.CreateBuilder(args);
var connectionString = builder.Configuration.GetConnectionString("appdb")
    ?? throw new InvalidOperationException("The appdb connection string is required.");
var provider = builder.Configuration["DatabaseProvider"] ?? "postgresql";
Func<DbConnection> createConnection = provider switch
{
    "postgresql" => () => new NpgsqlConnection(connectionString),
    "sqlserver" => () => new SqlConnection(connectionString),
    "sqlite" => () => new SqliteConnection(connectionString),
    _ => throw new InvalidOperationException("Choose a supported example database provider.")
};
var table = provider switch
{
    "postgresql" => "public.aspire_demo",
    "sqlserver" => "dbo.aspire_demo",
    _ => "aspire_demo"
};
builder.Services.AddSingleton(createConnection);

var app = builder.Build();
app.MapGet("/health", () => Results.Ok());
app.MapGet("/", async (Func<DbConnection> connectionFactory, CancellationToken cancellationToken) =>
{
    await using var connection = connectionFactory();
    await connection.OpenAsync(cancellationToken);
    await using var command = connection.CreateCommand();
    command.CommandText = $"SELECT message FROM {table} WHERE id = 1";
    var message = (string?)await command.ExecuteScalarAsync(cancellationToken);
    return message is null ? Results.NotFound() : Results.Text(message);
});
await app.RunAsync();

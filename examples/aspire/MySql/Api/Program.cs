using MySqlConnector;

var builder = WebApplication.CreateBuilder(args);
var connectionString = builder.Configuration.GetConnectionString("appdb")
    ?? throw new InvalidOperationException("The appdb connection string is required.");
var app = builder.Build();
app.MapGet("/health", () => Results.Ok());
app.MapGet("/", async (CancellationToken cancellationToken) =>
{
    await using var connection = new MySqlConnection(connectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = connection.CreateCommand();
    command.CommandText = "SELECT message FROM aspire_demo WHERE id = 1";
    var message = (string?)await command.ExecuteScalarAsync(cancellationToken);
    return message is null ? Results.NotFound() : Results.Text(message);
});
await app.RunAsync();

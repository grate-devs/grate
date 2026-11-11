using Npgsql;

var builder = WebApplication.CreateBuilder(args);
var connectionString = builder.Configuration.GetConnectionString("appdb")
    ?? throw new InvalidOperationException("The appdb connection string is required.");
builder.Services.AddSingleton(_ => NpgsqlDataSource.Create(connectionString));

var app = builder.Build();
app.MapGet("/health", () => Results.Ok());
app.MapGet("/", async (NpgsqlDataSource database, CancellationToken cancellationToken) =>
{
    await using var command = database.CreateCommand(
        "SELECT message FROM public.aspire_demo WHERE id = 1");
    var message = (string?)await command.ExecuteScalarAsync(cancellationToken);
    return message is null ? Results.NotFound() : Results.Text(message);
});
await app.RunAsync();

using System.Reflection;
using BigQuery.TestInfrastructure.Stub;
using Google.Cloud.BigQuery.V2;
using grate.BigQuery.Infrastructure;
using grate.BigQuery.Migration;
using grate.Infrastructure;
using grate.Migration;
using Microsoft.Extensions.Logging.Abstractions;

namespace BigQuery.Jobs;

// ReSharper disable once InconsistentNaming
public sealed class Cloned_databases : IAsyncDisposable
{
    private readonly BigQueryStub _first = new();
    private readonly BigQueryStub _second = new();

    [Theory]
    [InlineData("project-b", false, null)] // another project
    [InlineData("project-a", true, null)] // another endpoint
    [InlineData("project-a", false, "EU")] // another location
    public async Task A_clone_configured_for_another_target_reaches_that_target(string project, bool otherEndpoint, string? location)
    {
        var target = otherEndpoint ? _second : _first;
        await using var original = await StubDatabase.Initialize(_first);
        var clone = (BigQueryDatabase)original.Clone();
        await clone.InitializeConnections(StubDatabase.Configuration(target, project, location));

        // a script carries its own location, but a read of grate's tables takes the client's
        await clone.RunSql("SELECT 1", ConnectionType.Default, TransactionHandling.Default);
        await clone.HasRun("1_first.sql", TransactionHandling.Default);
        await clone.DropDatabase();
        await clone.DisposeAsync();

        // the clone's end leaves the original's client working
        await original.RunSql("SELECT 2", ConnectionType.Default, TransactionHandling.Default);

        var cloneJob = Assert.Single(target.Queries, x => x.Sql == "SELECT 1");
        Assert.Equal(project, cloneJob.Project);
        Assert.Equal(location, cloneJob.Location);
        var cloneRead = Assert.Single(target.Queries, x => x.Sql!.Contains("script_name"));
        Assert.Equal((project, location), (cloneRead.Project, cloneRead.Location));
        var drop = Assert.Single(target.Requests, x => x.Method == "DELETE");
        Assert.Equal((project, StubDatabase.Dataset), (drop.Project, drop.Dataset));
        var originalJob = Assert.Single(_first.Queries, x => x.Sql == "SELECT 2");
        Assert.Equal(("project-a", null), (originalJob.Project, originalJob.Location));
    }

    [Fact]
    public async Task The_last_database_to_let_go_disposes_the_client_also_after_a_failed_write()
    {
        // grate's bootstrap writes its records once the database is disposed, and BigQuery refuses this one
        _first.NewJob = request => request.Sql!.Contains("INSERT INTO") ? StubJob.Fails("accessDenied") : StubJob.Succeeds;
        var database = new BigQueryDatabase(NullLogger<BigQueryDatabase>.Instance);
        await database.InitializeConnections(
            StubDatabase.Configuration(_first) with { Environment = GrateEnvironment.InternalBootstrap });
        var client = ClientOf(database);
        await database.InsertScriptRun("1_first.sql", "SELECT 1", "hash", true, 1, TransactionHandling.Default);

        var exception = await Assert.ThrowsAsync<BigQueryDbException>(() => database.DisposeAsync().AsTask());

        Assert.Equal("accessDenied", exception.Reason);
        await Assert.ThrowsAsync<ObjectDisposedException>(() =>
            client.GetDatasetAsync(StubDatabase.Dataset, cancellationToken: TestContext.Current.CancellationToken));
    }

    // the client a database holds - nothing outside the provider can reach it
    private static BigQueryClient ClientOf(BigQueryDatabase database)
    {
        var shared = typeof(BigQueryDatabase)
            .GetField("_client", BindingFlags.NonPublic | BindingFlags.Instance)!
            .GetValue(database)!;
        return (BigQueryClient)shared.GetType().GetProperty("Client")!.GetValue(shared)!;
    }

    public async ValueTask DisposeAsync()
    {
        await _first.DisposeAsync();
        await _second.DisposeAsync();
    }
}

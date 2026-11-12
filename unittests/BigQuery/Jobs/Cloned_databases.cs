using BigQuery.TestInfrastructure.Stub;
using grate.BigQuery.Migration;
using grate.Migration;

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

    public async ValueTask DisposeAsync()
    {
        await _first.DisposeAsync();
        await _second.DisposeAsync();
    }
}

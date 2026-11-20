using BigQuery.TestInfrastructure.Stub;
using grate.BigQuery.Infrastructure;

namespace BigQuery.Jobs;

// ReSharper disable once InconsistentNaming
public sealed class Version_registration : IAsyncDisposable
{
    private readonly BigQueryStub _bigQuery = new();

    [Fact]
    public async Task A_refused_version_insert_fails_the_registration()
    {
        // the next id is 8, and BigQuery refuses the INSERT of version 8
        _bigQuery.NewJob = request => request.Sql!.Contains("MAX(id)")
            ? StubJob.Returns("id", "8")
            : StubJob.Fails("accessDenied");
        await using var database = await StubDatabase.Initialize(_bigQuery);

        var exception = await Assert.ThrowsAsync<BigQueryDbException>(() => database.VersionTheDatabase("1.2.3"));

        Assert.Equal("accessDenied", exception.Reason);
        Assert.Single(_bigQuery.Queries, x => x.Sql!.Contains("INSERT INTO"));
    }

    public ValueTask DisposeAsync() => _bigQuery.DisposeAsync();
}

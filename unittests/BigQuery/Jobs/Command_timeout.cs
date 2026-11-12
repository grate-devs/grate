using BigQuery.TestInfrastructure.Stub;
using grate.BigQuery.Infrastructure;
using grate.Migration;

namespace BigQuery.Jobs;

// ReSharper disable once InconsistentNaming
public sealed class Command_timeout : IAsyncDisposable
{
    private readonly BigQueryStub _bigQuery = new();

    [Fact]
    public async Task A_job_still_running_at_the_timeout_is_cancelled_and_reported_with_its_id()
    {
        _bigQuery.NewJob = _ => StubJob.Running;
        await using var database = await StubDatabase.Initialize(_bigQuery, commandTimeout: 1);

        var exception = await Assert.ThrowsAsync<BigQueryDbException>(() =>
            database.RunSql("UPDATE t SET x = 1 WHERE TRUE", ConnectionType.Default, TransactionHandling.Default));

        var jobId = Assert.Single(_bigQuery.CreatedJobIds);
        Assert.Equal(jobId, exception.JobId);
        Assert.Contains(jobId, exception.Message);
        var cancel = Assert.Single(_bigQuery.Cancels);
        Assert.Equal(jobId, cancel.JobId);
    }

    public ValueTask DisposeAsync() => _bigQuery.DisposeAsync();
}

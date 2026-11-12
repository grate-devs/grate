using BigQuery.TestInfrastructure.Stub;
using grate.BigQuery.Infrastructure;
using grate.Migration;

namespace BigQuery.Jobs;

// ReSharper disable once InconsistentNaming
public sealed class Job_identity : IAsyncDisposable
{
    private readonly BigQueryStub _bigQuery = new();

    [Fact]
    public async Task A_query_whose_answer_was_lost_runs_once()
    {
        // BigQuery starts the query, but its answer is lost on the way back
        _bigQuery.LoseAnswerTo = request => request.IsQuery && _bigQuery.Queries.Count == 1;
        await using var database = await StubDatabase.Initialize(_bigQuery);

        await database.RunSql("INSERT INTO t (id) VALUES (1)", ConnectionType.Default, TransactionHandling.Default);

        Assert.Equal(2, _bigQuery.Queries.Count);
        Assert.Single(_bigQuery.CreatedJobIds);
    }

    [Theory]
    [InlineData(false)] // the query fails before BigQuery answers it
    [InlineData(true)] // the query fails while grate waits for it
    public async Task A_query_that_failed_is_not_run_again(bool stillRunningWhenAnswered)
    {
        // a rate limit passes, but the statements of a script before the failure have run
        _bigQuery.NewJob = _ => stillRunningWhenAnswered
            ? StubJob.FailsAfter(1, "rateLimitExceeded")
            : StubJob.Fails("rateLimitExceeded");
        await using var database = await StubDatabase.Initialize(_bigQuery);

        var exception = await Assert.ThrowsAsync<BigQueryDbException>(() =>
            database.RunSql("UPDATE t SET x = 1 WHERE TRUE", ConnectionType.Default, TransactionHandling.Default));

        Assert.Equal("rateLimitExceeded", exception.Reason);
        var jobId = Assert.Single(_bigQuery.CreatedJobIds);

        // BigQuery's answer to a query that failed names no job
        Assert.Equal(stillRunningWhenAnswered ? jobId : null, exception.JobId);
    }

    public ValueTask DisposeAsync() => _bigQuery.DisposeAsync();
}

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

    [Theory]
    [InlineData(1)] // the first wait before sending again is longer than the timeout
    [InlineData(3)] // sent again after the first wait, the request would have less than a second left
    public async Task A_request_is_not_sent_again_without_time_left(int commandTimeout)
    {
        // BigQuery turns every query away
        _bigQuery.TurnAway = request => request.IsQuery;
        await using var database = await StubDatabase.Initialize(_bigQuery, commandTimeout: commandTimeout);

        var exception = await Assert.ThrowsAsync<BigQueryDbException>(() =>
            database.RunSql("UPDATE t SET x = 1 WHERE TRUE", ConnectionType.Default, TransactionHandling.Default));

        var query = Assert.Single(_bigQuery.Queries);
        Assert.Contains(query.RequestId!, exception.Message);
        Assert.Empty(_bigQuery.CreatedJobIds);
    }

    [Fact]
    public async Task A_request_sent_again_asks_BigQuery_to_hold_it_only_for_the_time_left()
    {
        // turned away once, then sent again 2 seconds into a 4-second timeout
        _bigQuery.TurnAway = request => request.IsQuery && _bigQuery.Queries.Count == 1;
        await using var database = await StubDatabase.Initialize(_bigQuery, commandTimeout: 4);

        await database.RunSql("UPDATE t SET x = 1 WHERE TRUE", ConnectionType.Default, TransactionHandling.Default);

        var timeouts = _bigQuery.Queries.Select(x => long.Parse(x.Body!["timeoutMs"]!.ToString())).ToArray();
        Assert.Equal(2, timeouts.Length);
        Assert.InRange(timeouts[0], 3000, 4000);
        Assert.InRange(timeouts[1], 1, 2999);
    }

    public ValueTask DisposeAsync() => _bigQuery.DisposeAsync();
}

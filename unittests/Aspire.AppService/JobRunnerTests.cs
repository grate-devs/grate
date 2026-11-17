using System.Threading.Channels;
using Azure.Core;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace Grate.Aspire.AppService.Tests;

public sealed class JobRunnerTests
{
    internal const string JobPath = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.App/jobs/appdb-grate";
    internal const string ExecutionPath = JobPath + "/executions/appdb-grate-exact";
    internal static readonly ResourceIdentifier JobId = new(JobPath);
    internal static readonly ResourceIdentifier ExecutionId = new(ExecutionPath);

    [Fact]
    public async Task Only_success_of_the_started_execution_unblocks_the_gate()
    {
        var clock = new ManualClock();
        var client = new JobClient("Pending", "Running", "Processing", "Succeeded");
        var deployment = Run(client, clock: clock, token: TestContext.Current.CancellationToken);

        await clock.AdvancePoll();
        Assert.False(deployment.IsCompleted);
        await clock.AdvancePoll();
        Assert.False(deployment.IsCompleted);
        await clock.AdvancePoll();
        await deployment.WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);

        Assert.Equal(JobId, Assert.Single(client.Starts));
        Assert.Equal([ExecutionId, ExecutionId, ExecutionId, ExecutionId], client.Reads);
    }

    [Theory]
    [InlineData("Failed")]
    [InlineData("Stopped")]
    [InlineData("Degraded")]
    [InlineData(null)]
    [InlineData("private-service-response-canary")]
    public async Task Failed_or_unknown_states_do_not_unlock_deployment(string? status)
    {
        var client = new JobClient(status);

        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => Run(client, token: TestContext.Current.CancellationToken));

        Assert.Contains("blocked", error.Message);
        Assert.DoesNotContain("private-service-response-canary", error.Message);
        Assert.Single(client.Starts);
        Assert.Equal(ExecutionId, Assert.Single(client.Reads));
    }

    [Fact]
    public async Task A_start_response_for_another_job_is_rejected_before_polling()
    {
        var client = new JobClient("Succeeded")
        {
            StartedExecution = new ResourceIdentifier(ExecutionPath.Replace("/jobs/appdb-grate/", "/jobs/other-job/", StringComparison.Ordinal))
        };

        await Assert.ThrowsAsync<InvalidOperationException>(() => Run(client, token: TestContext.Current.CancellationToken));

        Assert.Single(client.Starts);
        Assert.Empty(client.Reads);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("https://example.invalid")]
    [InlineData("/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Web/sites/api")]
    public async Task An_invalid_or_wrong_type_job_output_never_starts_a_job(string? jobPath)
    {
        var client = new JobClient("Succeeded");

        await Assert.ThrowsAsync<InvalidOperationException>(() => Run(client, _ => ValueTask.FromResult(jobPath), token: TestContext.Current.CancellationToken));

        Assert.Empty(client.Starts);
        Assert.Empty(client.Reads);
    }

    [Fact]
    public async Task Timeout_stops_polling_without_restarting_the_job()
    {
        var clock = new ManualClock();
        var client = new JobClient("Running", "Succeeded");
        var deployment = Run(client, clock: clock, token: TestContext.Current.CancellationToken);

        await clock.WaitForPoll();
        clock.ExpireDeadline();

        await Assert.ThrowsAsync<TimeoutException>(() => deployment.WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken));
        Assert.Single(client.Starts);
        Assert.Single(client.Reads);
    }

    [Fact]
    public async Task Cancelling_before_start_never_launches_an_execution()
    {
        using var cancel = new CancellationTokenSource();
        await cancel.CancelAsync();
        var client = new JobClient("Succeeded");

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Run(client, token: cancel.Token));

        Assert.Empty(client.Starts);
        Assert.Empty(client.Reads);
    }

    [Fact]
    public async Task Cancellation_reaching_an_in_flight_success_response_still_blocks_the_gate()
    {
        using var cancel = new CancellationTokenSource();
        var client = new JobClient("Succeeded") { OnRead = cancel.Cancel };

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Run(client, token: cancel.Token));

        Assert.Single(client.Starts);
        Assert.Single(client.Reads);
    }

    private static Task Run(JobClient client, Func<CancellationToken, ValueTask<string?>>? jobPath = null,
        TimeProvider? clock = null, CancellationToken token = default) =>
        GrateJobRunner.Run(client, jobPath ?? (_ => ValueTask.FromResult<string?>(JobPath)), TimeSpan.FromMinutes(1),
            clock ?? TimeProvider.System, NullLogger.Instance, token);

    private sealed class JobClient(params string?[] statuses) : IGrateJobClient
    {
        private readonly Queue<string?> _statuses = new(statuses);
        internal ResourceIdentifier StartedExecution { get; init; } = ExecutionId;
        internal Action? OnRead { get; init; }
        internal List<ResourceIdentifier> Starts { get; } = [];
        internal List<ResourceIdentifier> Reads { get; } = [];

        public Task<ResourceIdentifier> Start(ResourceIdentifier jobId, CancellationToken cancellationToken)
        {
            Starts.Add(jobId);
            return Task.FromResult(StartedExecution);
        }

        public Task<string?> GetStatus(ResourceIdentifier executionId, CancellationToken cancellationToken)
        {
            Reads.Add(executionId);
            OnRead?.Invoke();
            return Task.FromResult(_statuses.Dequeue());
        }
    }

    // Observe each configured poll or deadline without waiting for real elapsed time.
    private sealed class ManualClock : TimeProvider
    {
        private readonly Channel<ManualTimer> _polls = Channel.CreateUnbounded<ManualTimer>();
        private ManualTimer? _deadline;

        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
        {
            var timer = new ManualTimer(callback, state);
            if (dueTime == TimeSpan.FromMinutes(1))
            {
                _deadline = timer;
            }
            else
            {
                _polls.Writer.TryWrite(timer);
            }
            return timer;
        }

        internal async Task AdvancePoll() => (await WaitForPoll()).Fire();
        internal async Task<ManualTimer> WaitForPoll() => await _polls.Reader.ReadAsync(TestContext.Current.CancellationToken)
            .AsTask().WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
        internal void ExpireDeadline() => _deadline!.Fire();
    }

    private sealed class ManualTimer(TimerCallback callback, object? state) : ITimer
    {
        internal void Fire() => callback(state);
        public bool Change(TimeSpan dueTime, TimeSpan period) => throw new NotSupportedException();
        public void Dispose() { }
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}

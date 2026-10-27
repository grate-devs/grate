using Docker.Common.TestInfrastructure;
using DotNet.Testcontainers.Containers;
using grate.Exceptions;
using Microsoft.Extensions.Logging.Abstractions;
using NSubstitute;

namespace Basic_tests.Infrastructure;

public sealed class DockerMigrationRunner_
{
    private readonly IContainer _container = Substitute.For<IContainer>();

    [Fact]
    public async Task Startup_failure_is_preserved_when_the_container_has_no_logs()
    {
        var startupFailure = new InvalidOperationException("The application image could not be pulled.");
        _container.StartAsync(Arg.Any<CancellationToken>()).Returns(Task.FromException(startupFailure));
        FailLogCapture();

        var failure = await Assert.ThrowsAsync<MigrationFailed>(Run);

        Assert.Same(startupFailure, Assert.Single(failure.InnerExceptions));
        await _container.DidNotReceive().GetExitCodeAsync(Arg.Any<CancellationToken>());
        await _container.Received(1).DisposeAsync();
    }

    [Fact]
    public async Task Completion_cancellation_is_preserved_when_log_capture_also_fails()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        _container.GetExitCodeAsync(Arg.Any<CancellationToken>())
            .Returns(Task.FromCanceled<long>(cancellation.Token));
        FailLogCapture();

        var failure = await Assert.ThrowsAsync<MigrationFailed>(Run);

        var cancelled = Assert.IsAssignableFrom<OperationCanceledException>(Assert.Single(failure.InnerExceptions));
        Assert.Equal(cancellation.Token, cancelled.CancellationToken);
        await _container.Received(1).DisposeAsync();
    }

    [Fact]
    public async Task Nonzero_exit_includes_the_exit_code_and_both_output_streams()
    {
        _container.GetExitCodeAsync(Arg.Any<CancellationToken>()).Returns(7L);
        _container.GetLogsAsync(Arg.Any<DateTime>(), Arg.Any<DateTime>(), Arg.Any<bool>(), Arg.Any<CancellationToken>())
            .Returns(("migration output", "migration error"));

        var failure = await Assert.ThrowsAsync<MigrationFailed>(Run);

        Assert.Contains("exit code 7", failure.Message);
        Assert.Contains("migration output", failure.Message);
        Assert.Contains("migration error", failure.Message);
    }

    [Fact]
    public async Task Nonzero_exit_remains_a_failure_when_logs_are_unavailable()
    {
        _container.GetExitCodeAsync(Arg.Any<CancellationToken>()).Returns(7L);
        FailLogCapture();

        var failure = await Assert.ThrowsAsync<MigrationFailed>(Run);

        Assert.Contains("exit code 7", failure.Message);
    }

    [Fact]
    public async Task Successful_completion_waits_with_the_execution_token_and_cleans_up()
    {
        using var execution = new CancellationTokenSource();

        await DockerMigrationRunner.Run(_container, NullLogger.Instance, execution.Token);

        await _container.Received(1).StartAsync(execution.Token);
        await _container.Received(1).GetExitCodeAsync(execution.Token);
        await _container.Received(1).DisposeAsync();
    }

    [Fact]
    public async Task Cleanup_failure_does_not_replace_the_execution_failure()
    {
        var startupFailure = new InvalidOperationException("The application image could not be pulled.");
        _container.StartAsync(Arg.Any<CancellationToken>()).Returns(Task.FromException(startupFailure));
        _container.When(container => container.DisposeAsync().AsTask())
            .Do(_ => throw new IOException("Docker cleanup failed."));
        FailLogCapture();

        var failure = await Assert.ThrowsAsync<MigrationFailed>(Run);

        Assert.Same(startupFailure, Assert.Single(failure.InnerExceptions));
    }

    [Fact]
    public async Task Cleanup_failure_is_reported_after_an_otherwise_successful_migration()
    {
        var cleanupFailure = new IOException("Docker cleanup failed.");
        _container.When(container => container.DisposeAsync().AsTask()).Do(_ => throw cleanupFailure);

        var failure = await Assert.ThrowsAsync<MigrationFailed>(Run);

        Assert.Same(cleanupFailure, Assert.Single(failure.InnerExceptions));
    }

    private Task Run() => DockerMigrationRunner.Run(_container, NullLogger.Instance, CancellationToken.None);

    private void FailLogCapture() =>
        _container.GetLogsAsync(Arg.Any<DateTime>(), Arg.Any<DateTime>(), Arg.Any<bool>(), Arg.Any<CancellationToken>())
            .Returns(Task.FromException<(string, string)>(new InvalidOperationException("Could not find resource 'DockerContainer'.")));
}

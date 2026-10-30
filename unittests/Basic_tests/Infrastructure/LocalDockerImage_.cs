using System.Text;
using Docker.Common.TestInfrastructure;
using Microsoft.Extensions.Logging.Abstractions;

namespace Basic_tests.Infrastructure;

public sealed class LocalDockerImage_ : IDisposable
{
    private readonly string _root = Directory.CreateTempSubdirectory("grate lazy image tests-").FullName;

    [Fact]
    public async Task Merely_preparing_a_plan_does_not_build_an_image()
    {
        CreatePlan();

        Assert.Empty(BuildEvents());
        await LocalDockerImage.Ensure("grate-local:tests", Path.Combine(_root, "missing-plan"),
            NullLogger.Instance, TestContext.Current.CancellationToken);
        Assert.Empty(BuildEvents());
    }

    [Theory]
    [InlineData("custom:tests")]
    [InlineData("gratedevs/grate")]
    public async Task Other_images_are_not_built(string image)
    {
        await Ensure(image, CreatePlan());

        Assert.Empty(BuildEvents());
    }

    [Fact]
    public async Task Concurrent_migrations_share_one_build()
    {
        var plan = CreatePlan();
        Assert.Empty(BuildEvents());

        await Task.WhenAll(Enumerable.Range(0, 16).Select(_ => Ensure("grate-local:tests", plan)));

        Assert.Equal(["build"], BuildEvents());
        Assert.True(File.Exists(plan + ".built"));
    }

    [Fact]
    public async Task A_new_test_build_prepares_a_fresh_image_build()
    {
        await Ensure("grate-local:tests", CreatePlan());
        await Ensure("grate-local:tests", CreatePlan());

        Assert.Equal(["build", "build"], BuildEvents());
    }

    [Fact]
    public async Task Separate_plans_preserve_their_own_build_commands()
    {
        var successfulPlan = CreatePlan();
        var failingPlan = CreatePlan(exitCode: 17);

        await Ensure("grate-local:tests", successfulPlan);
        var failure = await Assert.ThrowsAsync<InvalidOperationException>(() => Ensure("grate-local:tests", failingPlan));

        Assert.Contains("exit code 17", failure.Message);
        Assert.True(File.Exists(successfulPlan + ".built"));
        Assert.False(File.Exists(failingPlan + ".built"));
        Assert.Equal(["build", "build"], BuildEvents());
    }

    [Fact]
    public async Task An_already_completed_shared_plan_does_not_rebuild()
    {
        var plan = CreatePlan();
        await File.WriteAllTextAsync(plan + ".built", "grate-local:tests", TestContext.Current.CancellationToken);

        await Ensure("grate-local:tests", plan);

        Assert.Empty(BuildEvents());
    }

    [Fact]
    public async Task Failed_build_preserves_diagnostics_and_is_not_retried()
    {
        var plan = CreatePlan(exitCode: 17);

        var failure = await Assert.ThrowsAsync<InvalidOperationException>(() => Ensure("grate-local:tests", plan));
        Assert.Contains("exit code 17", failure.Message);
        Assert.Contains("fake Docker build failure", failure.Message);
        await Assert.ThrowsAsync<InvalidOperationException>(() => Ensure("grate-local:tests", plan));

        Assert.Equal(["build"], BuildEvents());
        Assert.False(File.Exists(plan + ".built"));
        Assert.Contains("exit code 17", await File.ReadAllTextAsync(plan + ".failed", TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task Failure_to_save_shared_status_does_not_hide_the_Docker_failure()
    {
        var plan = CreatePlan(exitCode: 17);
        Directory.CreateDirectory(plan + ".failed");

        var failure = await Assert.ThrowsAsync<InvalidOperationException>(() => Ensure("grate-local:tests", plan));

        Assert.Contains("exit code 17", failure.Message);
        Assert.Contains("fake Docker build failure", failure.Message);
        Assert.Equal(["build"], BuildEvents());
    }

    [Fact]
    public async Task Another_module_reports_the_shared_build_failure_without_retrying()
    {
        var plan = CreatePlan();
        await File.WriteAllTextAsync(plan + ".failed", "A previous module's Docker build failed with exit code 17.",
            TestContext.Current.CancellationToken);

        var failure = await Assert.ThrowsAsync<InvalidOperationException>(() => Ensure("grate-local:tests", plan));

        Assert.Contains("exit code 17", failure.Message);
        Assert.Empty(BuildEvents());
    }

    [Fact]
    public async Task Waiting_for_another_module_can_be_cancelled()
    {
        var plan = CreatePlan();
        await using var imageLock = new FileStream(plan + ".lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        cancellation.CancelAfter(TimeSpan.FromMilliseconds(100));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            LocalDockerImage.Ensure("grate-local:tests", plan, NullLogger.Instance, cancellation.Token));

        Assert.Empty(BuildEvents());
    }

    private Task Ensure(string image, string plan) =>
        LocalDockerImage.Ensure(image, plan, NullLogger.Instance, TestContext.Current.CancellationToken);

    private string CreatePlan(int exitCode = 0)
    {
        var commandDirectory = Directory.CreateDirectory(Path.Combine(_root, Guid.NewGuid().ToString())).FullName;
        var windows = OperatingSystem.IsWindows();
        // Run Unix scripts through the stable shell executable to avoid Linux ETXTBSY
        // races when other tests fork while a temporary executable is being written.
        // RunBuild passes "build" first, so the shell reads that file in its working directory.
        var docker = windows ? Path.Combine(commandDirectory, "docker.cmd") : "/bin/sh";
        var scriptPath = windows ? docker : Path.Combine(commandDirectory, "build");
        var events = Path.Combine(_root, "events.txt");
        var script = windows
            ? $"@echo off\r\necho build>>\"{events}\"\r\necho fake Docker build failure 1>&2\r\nexit /b {exitCode}\r\n"
            : $"#!/bin/sh\nprintf 'build\\n' >> '{events}'\nprintf 'fake Docker build failure\\n' >&2\nexit {exitCode}\n";
        File.WriteAllText(scriptPath, script, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));

        var plan = Path.Combine(_root, Guid.NewGuid() + ".plan");
        File.WriteAllLines(plan, [commandDirectory, docker, plan]);
        return plan;
    }

    private string[] BuildEvents() => File.Exists(Path.Combine(_root, "events.txt"))
        ? File.ReadAllLines(Path.Combine(_root, "events.txt")) : [];

    public void Dispose() => Directory.Delete(_root, recursive: true);
}

using System.Diagnostics;
using grate;

namespace Basic_tests.CommandLineParsing;

public sealed class CliInvocationTests
{
    [Theory]
    [InlineData(new[] { "--help" }, "--connectionstring")]
    [InlineData(new[] { "--databasetype", "999", "--help" }, "--connectionstring")]
    [InlineData(new[] { "skills", "--help" }, "install")]
    [InlineData(new[] { "skills", "install", "--help" }, "--local")]
    public async Task Help_succeeds_without_migration_configuration(string[] arguments, string expectedOption)
    {
        var result = await Invoke(arguments);

        Assert.Equal(0, result.ExitCode);
        Assert.Contains(expectedOption, result.Output);
        Assert.Empty(result.Error);
    }

    [Theory]
    [InlineData(new string[0], "--connectionstring")]
    [InlineData(new[] { "--connectionstring", "unused", "--databasetype", "invalid" }, "--databasetype")]
    [InlineData(new[] { "--connectionstring", "unused", "--commandtimeout", "invalid" }, "--commandtimeout")]
    public async Task Invalid_arguments_report_parse_errors_without_starting_a_migration(string[] arguments, string expectedOption)
    {
        var result = await Invoke(arguments);

        Assert.Equal(1, result.ExitCode);
        Assert.Contains(expectedOption, result.Error);
        Assert.DoesNotContain("Unhandled exception", result.Error);
        Assert.DoesNotContain("An error occurred:", result.Error);
    }

    [Fact]
    public async Task Migration_failures_keep_the_existing_error_message_and_exit_code()
    {
        var result = await Invoke("--databasetype", "sqlite", "--connectionstring", "invalid", "--silent");

        Assert.Equal(1, result.ExitCode);
        Assert.Contains("An error occurred:", result.Error);
        Assert.DoesNotContain("Unhandled exception", result.Error);
    }

    [Fact]
    public async Task Skills_install_runs_without_a_connection_string()
    {
        var root = Directory.CreateTempSubdirectory("grate-cli-skills-");
        try
        {
            var result = await Invoke("skills", "install", "--local", "--path", root.FullName);

            Assert.Equal(0, result.ExitCode);
            Assert.Empty(result.Error);
            foreach (var agent in new[] { ".agents", ".claude" })
            {
                Assert.True(File.Exists(Path.Combine(root.FullName, agent, "skills", "use-grate", "SKILL.md")));
            }
        }
        finally
        {
            root.Delete(recursive: true);
        }
    }

    private static async Task<(int ExitCode, string Output, string Error)> Invoke(params string[] arguments)
    {
        var start = new ProcessStartInfo(Environment.GetEnvironmentVariable("DOTNET_HOST_PATH") ?? "dotnet")
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        start.ArgumentList.Add(typeof(Program).Assembly.Location);
        foreach (var argument in arguments)
        {
            start.ArgumentList.Add(argument);
        }

        using var process = Process.Start(start) ?? throw new InvalidOperationException("Could not start grate CLI.");
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        cancellation.CancelAfter(TimeSpan.FromSeconds(30));
        try
        {
            await process.WaitForExitAsync(cancellation.Token);
        }
        catch (OperationCanceledException)
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync(CancellationToken.None);
            throw;
        }

        return (process.ExitCode, await output, await error);
    }
}

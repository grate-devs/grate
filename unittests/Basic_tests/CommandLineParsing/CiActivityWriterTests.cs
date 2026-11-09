using grate.Configuration;
using grate.Infrastructure;
using Microsoft.Extensions.Logging;

namespace Basic_tests.CommandLineParsing;

public sealed class CiActivityWriterTests
{
    [Theory]
    [InlineData("GitHub", "::group::", "::endgroup::", "25%25 | [x]; 'title'%0D%0A::endgroup::", 3)]
    [InlineData("AzureDevOps", "##[group]", "##[endgroup]", "25% | [x]; 'title' ::endgroup::", 4)]
    [InlineData("TeamCity", "##teamcity[blockOpened ", "##teamcity[blockClosed ", "25% || |[x|]; |'title|'|r|n::endgroup::", 5)]
    public void Activity_titles_are_escaped_and_disposal_balances_commands_without_reporting_success(
        string format, string start, string finish, string escapedTitle, int expectedLines)
    {
        using var output = new StringWriter();
        var provider = new MigrationLoggerProvider(Enum.Parse<MigrationLogFormat>(format), output);
        var logger = provider.CreateLogger("Grate.Migration");
        using (logger.BeginScope(new MigrationLogActivity(
                   "25% | [x]; 'title'\r\n::endgroup:: ##vso[task.complete] ##teamcity[buildProblem] ##[endgroup]\u001b\u2028")))
        {
            logger.LogInformation("Script executed.");
        }

        provider.Dispose();
        provider.Dispose();

        var lines = Lines(output.ToString());
        Assert.Equal(expectedLines, lines.Length);
        var group = Assert.Single(lines, line => line.StartsWith(start, StringComparison.Ordinal));
        Assert.Contains(escapedTitle, group);
        Assert.Single(lines, line => line.StartsWith(finish, StringComparison.Ordinal));
        Assert.Contains(@"\u001B\u2028", group);
        Assert.DoesNotContain("✅", output.ToString());
        Assert.DoesNotContain("value=100", output.ToString());
        foreach (var line in lines)
        {
            // Remove the first trusted envelope, then reject any additional command.
            var payload = line.StartsWith("##", StringComparison.Ordinal)
                ? line[(line.IndexOf('[', StringComparison.Ordinal) + 1)..]
                : line;
            Assert.DoesNotContain("##vso[", payload);
            Assert.DoesNotContain("##teamcity[", payload);
            Assert.DoesNotContain("##[", payload);
            Assert.False(line.StartsWith("::endgroup:: ", StringComparison.Ordinal));
        }
    }

    [Theory]
    [InlineData("GitHub")]
    [InlineData("AzureDevOps")]
    [InlineData("TeamCity")]
    public void Filtered_information_does_not_open_groups_or_report_completion(string format)
    {
        using var output = new StringWriter();
        using var provider = new MigrationLoggerProvider(Enum.Parse<MigrationLogFormat>(format), output);
        using var factory = LoggerFactory.Create(builder => builder
            .AddProvider(provider)
            .AddFilter("Grate.Migration", LogLevel.Warning));
        var logger = factory.CreateLogger("Grate.Migration");
        using (logger.BeginScope(new MigrationLogActivity("Filtered activity")))
        {
            logger.LogInformation("Hidden progress.");
            logger.LogWarning("Visible diagnostic.");
        }

        provider.Complete(logger);

        var line = Assert.Single(Lines(output.ToString()));
        Assert.Contains("Visible diagnostic.", line);
        Assert.DoesNotContain("Filtered activity", line);
        Assert.DoesNotContain("✅", line);
    }

    [Fact]
    public void Azure_progress_measures_folder_dispatch_and_reserves_a_unit_for_finalization()
    {
        using var output = new StringWriter();
        using var provider = new MigrationLoggerProvider(MigrationLogFormat.AzureDevOps, output);
        var logger = provider.CreateLogger("Grate.Migration");
        using (logger.BeginScope(new MigrationLogActivity("First folder", completedFolders: 1, totalFolders: 3)))
        {
            logger.LogInformation("First.");
        }
        using (logger.BeginScope(new MigrationLogActivity("Finalizing", completedFolders: 3, totalFolders: 3)))
        {
            logger.LogInformation("Finalizing.");
        }

        Assert.Contains("##vso[task.setprogress value=25;]", output.ToString());
        Assert.Contains("##vso[task.setprogress value=75;]", output.ToString());
        Assert.DoesNotContain("value=100", output.ToString());

        provider.Complete(logger);

        Assert.Contains("##vso[task.setprogress value=100;]", output.ToString());
        Assert.EndsWith("[INFO] ✅ Migration completed." + Environment.NewLine, output.ToString());
    }

    private static string[] Lines(string output) => output.Split(["\r\n", "\n", "\r"], StringSplitOptions.RemoveEmptyEntries);
}

using System.Globalization;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace Basic_tests.CommandLineParsing;

public sealed class CliCiActivityTests : IDisposable
{
    private readonly DirectoryInfo _root = Directory.CreateTempSubdirectory("grate-ci-activities-");

    [Theory]
    [InlineData("github", false)]
    [InlineData("github", true)]
    [InlineData("azure", false)]
    [InlineData("azure", true)]
    [InlineData("teamcity", false)]
    [InlineData("teamcity", true)]
    public async Task Native_groups_contain_scripts_and_close_on_success_and_failure(string format, bool fails)
    {
        WriteScript("up", "01-activity.sql", fails ? "SELECT * FROM missing_table;" : "SELECT 1;");
        WriteScript("permissions", "02-followup.sql", "SELECT 2;");

        var result = await Migrate(format);

        Assert.Equal(fails ? 1 : 0, result.ExitCode);
        Assert.Empty(result.Error);
        var lines = Lines(result.Output);
        AssertBalancedGroups(format, lines, "01-activity.sql");
        Assert.Contains("02-followup.sql", result.Output);
        Assert.Contains(fails ? "❌" : "✅", result.Output);
        if (fails)
        {
            Assert.DoesNotContain("✅", result.Output);
        }
        if (format == "teamcity")
        {
            AssertBalancedTeamCityProgress(lines);
        }
        if (format == "azure")
        {
            var percentages = Regex.Matches(result.Output, @"##vso\[task\.setprogress value=(\d+);")
                .Select(match => int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture)).ToArray();
            Assert.NotEmpty(percentages);
            Assert.Equal(percentages.Order(), percentages);
            Assert.All(percentages, value => Assert.InRange(value, 0, 100));
            if (fails)
            {
                Assert.DoesNotContain(100, percentages);
            }
            else
            {
                Assert.Equal(100, percentages[^1]);
                Assert.Single(percentages, value => value == 100);
            }
        }
    }

    [Theory]
    [InlineData("github", "--verbosity=Warning")]
    [InlineData("azure", "--verbosity=Warning")]
    [InlineData("teamcity", "--verbosity=Warning")]
    [InlineData("github", "--isuptodate")]
    [InlineData("azure", "--isuptodate")]
    [InlineData("teamcity", "--isuptodate")]
    public async Task Quiet_and_up_to_date_modes_do_not_emit_activity_commands(string format, string option)
    {
        WriteScript("up", "01-activity.sql", "SELECT 1;");

        var result = await Migrate(format, option);

        Assert.Equal(0, result.ExitCode);
        Assert.Empty(result.Error);
        if (option == "--isuptodate")
        {
            Assert.Equal(["Up to date: False"], Lines(result.Output));
        }
        else
        {
            Assert.Empty(result.Output);
        }
    }

    [Theory]
    [InlineData("console")]
    [InlineData("ci")]
    public async Task Console_and_plain_ci_keep_their_existing_text_without_native_commands(string format)
    {
        WriteScript("up", "01-activity.sql", "SELECT 1;");

        var result = await Migrate(format);

        Assert.Equal(0, result.ExitCode);
        Assert.Contains("has grated your database", result.Output);
        Assert.DoesNotContain("::group::", result.Output);
        Assert.DoesNotContain("##vso[", result.Output);
        Assert.DoesNotContain("##teamcity[", result.Output);
        Assert.DoesNotContain("##[", result.Output);
        Assert.DoesNotContain("✅", result.Output);
    }

    [Theory]
    [InlineData("--dryrun", "Preview completed.")]
    [InlineData("--baseline", "Baseline completed.")]
    public async Task Preview_and_baseline_status_describe_the_operation_without_claiming_a_migration(
        string option, string status)
    {
        WriteScript("up", "01-not-executed.sql", "SELECT * FROM missing_table;");

        var result = await Migrate("azure", option);

        Assert.Equal(0, result.ExitCode);
        Assert.Empty(result.Error);
        Assert.Contains("[INFO] ✅ " + status, result.Output);
        Assert.DoesNotContain("✅ Migration completed.", result.Output);
        Assert.Contains("##vso[task.setprogress value=100;]" + status, result.Output);
    }

    private static void AssertBalancedGroups(string format, string[] lines, string script)
    {
        var start = format switch
        {
            "github" => "::group::",
            "azure" => "##[group]",
            _ => "##teamcity[blockOpened name='"
        };
        var end = format switch
        {
            "github" => "::endgroup::",
            "azure" => "##[endgroup]",
            _ => "##teamcity[blockClosed name='"
        };
        string? active = null;
        var groups = 0;
        var scriptWasGrouped = false;
        foreach (var line in lines)
        {
            if (line.StartsWith(start, StringComparison.Ordinal))
            {
                Assert.Null(active);
                active = line[start.Length..];
                groups++;
            }
            else if (line.StartsWith(end, StringComparison.Ordinal))
            {
                Assert.NotNull(active);
                if (format == "teamcity")
                {
                    Assert.Equal(active, line[end.Length..]);
                }
                active = null;
            }
            else if (line.Contains(script, StringComparison.Ordinal) && line.StartsWith("[INFO]", StringComparison.Ordinal))
            {
                Assert.NotNull(active);
                scriptWasGrouped = true;
            }
            else if (line.StartsWith("::error::", StringComparison.Ordinal)
                     || line.StartsWith("##vso[task.logissue type=error;]", StringComparison.Ordinal)
                     || line.EndsWith(" status='ERROR']", StringComparison.Ordinal)
                     || line.StartsWith("[INFO] ✅", StringComparison.Ordinal)
                     || line.StartsWith("[INFO] ❌", StringComparison.Ordinal))
            {
                Assert.Null(active);
            }
        }
        Assert.Null(active);
        Assert.True(groups >= 4, $"Expected setup, structure, versioning and folder groups: {string.Join(Environment.NewLine, lines)}");
        Assert.True(scriptWasGrouped, "The script execution log must appear inside a native group.");
    }

    private static void AssertBalancedTeamCityProgress(string[] lines)
    {
        const string start = "##teamcity[progressStart '";
        const string end = "##teamcity[progressFinish '";
        var messages = new Queue<string>();
        foreach (var line in lines)
        {
            if (line.StartsWith(start, StringComparison.Ordinal))
            {
                Assert.Empty(messages);
                messages.Enqueue(line[start.Length..]);
            }
            else if (line.StartsWith(end, StringComparison.Ordinal))
            {
                Assert.NotEmpty(messages);
                Assert.Equal(messages.Dequeue(), line[end.Length..]);
            }
        }
        Assert.Empty(messages);
        Assert.Contains(lines, line => line.StartsWith(start, StringComparison.Ordinal));
    }

    private void WriteScript(string folder, string name, string sql)
    {
        File.WriteAllText(Path.Combine(_root.CreateSubdirectory(folder).FullName, name), sql);
    }

    private Task<(int ExitCode, string Output, string Error)> Migrate(string format, params string[] arguments)
    {
        var connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = Path.Combine(_root.FullName, "test.db"),
            Pooling = false
        }.ToString();
        return CliInvocationTests.Invoke(
            ["--databasetype=sqlite", "--connectionstring=" + connectionString,
                "--files=" + _root.FullName, "--output=" + Path.Combine(_root.FullName, "output"),
                "--silent", "--log-format=" + format, .. arguments], []);
    }

    private static string[] Lines(string output) => output.Split(["\r\n", "\n", "\r"], StringSplitOptions.RemoveEmptyEntries);

    public void Dispose() => _root.Delete(recursive: true);
}

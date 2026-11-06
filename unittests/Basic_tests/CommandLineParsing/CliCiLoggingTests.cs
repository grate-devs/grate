using Microsoft.Data.Sqlite;

namespace Basic_tests.CommandLineParsing;

public sealed class CliCiLoggingTests : IDisposable
{
    private const string TransactionWarning = "support DDL transactions";
    private readonly DirectoryInfo _root = Directory.CreateTempSubdirectory("grate-cli-logging-");

    private string ConnectionString => new SqliteConnectionStringBuilder
    {
        DataSource = Path.Combine(_root.FullName, "test.db"),
        Pooling = false
    }.ToString();

    [Theory]
    [InlineData("GITHUB_ACTIONS", "TrUe", "::warning::")]
    [InlineData("TF_BUILD", "True", "##vso[task.logissue type=warning;]")]
    [InlineData("TEAMCITY_VERSION", "2026.2", "##teamcity[message ")]
    [InlineData("JENKINS_URL", "https://jenkins.example/", "[WARNING]")]
    [InlineData("BUILD_TAG", "jenkins-migration-1", "[WARNING]")]
    [InlineData("CI", "TRUE", "[WARNING]")]
    public async Task Runner_detection_reports_a_warning_from_a_successful_migration_on_stdout(
        string variable, string value, string warningPrefix)
    {
        WriteScript("up", "create_example.sql", "CREATE TABLE example (value TEXT);");
        var result = await Migrate([(variable, value)], "--transaction");

        Assert.Equal(0, result.ExitCode);
        Assert.Empty(result.Error);
        var warning = Assert.Single(Lines(result.Output), line => line.Contains(TransactionWarning, StringComparison.Ordinal));
        Assert.StartsWith(warningPrefix, warning);
        if (variable == "TEAMCITY_VERSION")
        {
            Assert.EndsWith(" status='WARNING']", warning);
        }
        Assert.Contains("[INFO]", result.Output);
        Assert.DoesNotContain('\u001b', result.Output);

        using var db = new SqliteConnection(ConnectionString);
        await db.OpenAsync(TestContext.Current.CancellationToken);
        using var command = db.CreateCommand();
        command.CommandText = "SELECT name FROM sqlite_master WHERE name = 'example';";
        Assert.Equal("example", await command.ExecuteScalarAsync(TestContext.Current.CancellationToken));
    }

    [Theory]
    [InlineData("GITHUB_ACTIONS", "true", "TF_BUILD", "True")]
    [InlineData("GITHUB_ACTIONS", "true", "JENKINS_URL", "https://jenkins.example/")]
    public async Task Multiple_providers_select_plain_ci_output(
        string first, string firstValue, string second, string secondValue)
    {
        var result = await Migrate([(first, firstValue), (second, secondValue), ("CI", "true")], "--transaction");

        Assert.Equal(0, result.ExitCode);
        Assert.Empty(result.Error);
        Assert.StartsWith("[WARNING]", Assert.Single(Lines(result.Output),
            line => line.Contains(TransactionWarning, StringComparison.Ordinal)));
    }

    [Theory]
    [InlineData("false", "", "false")]
    [InlineData("", "FaLsE", "")]
    public async Task Inactive_boolean_signals_keep_console_routing(string github, string azure, string ci)
    {
        var result = await Migrate(
            [("GITHUB_ACTIONS", github), ("TF_BUILD", azure), ("CI", ci), ("TEAMCITY_VERSION", ""), ("BUILD_TAG", "other-build")],
            "--transaction");

        Assert.Equal(0, result.ExitCode);
        Assert.Contains(TransactionWarning, result.Error);
        Assert.DoesNotContain(TransactionWarning, result.Output);
        Assert.DoesNotContain("[INFO]", result.Output);
    }

    [Theory]
    [InlineData("console", null)]
    [InlineData("ci", "[WARNING]")]
    [InlineData("github", "::warning::")]
    [InlineData("azure-devops", "##vso[task.logissue type=warning;]")]
    [InlineData("azure", "##vso[task.logissue type=warning;]")]
    [InlineData("teamcity", "##teamcity[message ")]
    public async Task Explicit_format_overrides_detection(string format, string? warningPrefix)
    {
        var result = await Migrate([("JENKINS_URL", "https://jenkins.example/")], "--transaction", "--log-format=" + format);

        Assert.Equal(0, result.ExitCode);
        if (warningPrefix is null)
        {
            Assert.Contains(TransactionWarning, result.Error);
            Assert.DoesNotContain(TransactionWarning, result.Output);
        }
        else
        {
            Assert.Empty(result.Error);
            Assert.StartsWith(warningPrefix, Assert.Single(Lines(result.Output),
                line => line.Contains(TransactionWarning, StringComparison.Ordinal)));
        }
    }

    [Theory]
    [InlineData("GITHUB_ACTIONS", "true", "::error::", "%0D%0A", "%25")]
    [InlineData("TF_BUILD", "True", "##vso[task.logissue type=error;]", "%0D%0A", "%AZP25")]
    [InlineData("TEAMCITY_VERSION", "2026.2", "##teamcity[message ", "|r|n", "%")]
    public async Task Native_errors_report_one_actionable_annotation_and_do_not_run_embedded_commands(
        string variable, string value, string prefix, string newline, string percent)
    {
        const string script = "broken ##vso[task.setvariable variable=injected] ##teamcity[buildProblem] ##[error]legacy.sql";
        WriteScript("up", script, """
            CREATE TABLE example (value TEXT);
            CREATE TRIGGER reject_insert BEFORE INSERT ON example
            BEGIN
                SELECT RAISE(ABORT, 'first 25% | [brackets]; ''quote''
            ::error::injected
            last ##vso[task.setvariable variable=injected] ##teamcity[buildProblem] ##[error]legacy');
            END;
            INSERT INTO example VALUES ('x');
            """.ReplaceLineEndings("\r\n"));

        var result = await Migrate([(variable, value)]);

        Assert.Equal(1, result.ExitCode);
        Assert.Empty(result.Error);
        var lines = Lines(result.Output);
        var error = Assert.Single(lines, line => line.StartsWith(prefix, StringComparison.Ordinal));
        Assert.Contains("broken", error);
        Assert.Contains("SQLite Error", error);
        Assert.Contains("first 25" + percent, error);
        Assert.Contains(newline, error);
        Assert.Contains("last", error);
        Assert.DoesNotContain("at grate.", result.Output);
        if (variable == "TEAMCITY_VERSION")
        {
            Assert.EndsWith(" status='ERROR']", error);
            Assert.Contains("|| |[brackets|]; |'quote|'", error);
        }
        else if (variable == "TF_BUILD")
        {
            Assert.Contains("brackets%5D%3B", error);
        }

        Assert.Contains(lines, line => line.StartsWith("[INFO]", StringComparison.Ordinal)
            && line.Contains("broken", StringComparison.Ordinal));
        foreach (var line in lines)
        {
            var payload = line == error ? line[prefix.Length..] : line;
            Assert.DoesNotContain("##vso[", payload);
            Assert.DoesNotContain("##teamcity[", payload);
            Assert.DoesNotContain("##[", payload);
            Assert.False(payload.TrimStart().StartsWith("::error::", StringComparison.Ordinal), line);
        }
    }

    [Fact]
    public async Task A_startup_failure_without_a_script_is_reported_once()
    {
        var result = await CliInvocationTests.Invoke(
            ["--databasetype=sqlite", "--connectionstring=invalid", "--silent"],
            [("GITHUB_ACTIONS", "true")]);

        Assert.Equal(1, result.ExitCode);
        Assert.Empty(result.Error);
        var error = Assert.Single(Lines(result.Output), line => line.StartsWith("::error::", StringComparison.Ordinal));
        Assert.Contains("initialization string", error, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("Unhandled exception", result.Output);
    }

    [Fact]
    public async Task Identical_database_errors_from_different_scripts_remain_distinct()
    {
        WriteScript("up", "first.sql", "SELECT * FROM missing_table;");
        WriteScript("permissions", "second.sql", "SELECT * FROM missing_table;");

        var result = await Migrate([("GITHUB_ACTIONS", "true")]);

        Assert.Equal(1, result.ExitCode);
        var errors = Lines(result.Output).Where(line => line.StartsWith("::error::", StringComparison.Ordinal)).ToArray();
        Assert.Equal(2, errors.Length);
        Assert.Contains(errors, line => line.Contains("first.sql", StringComparison.Ordinal) && line.Contains("missing_table", StringComparison.Ordinal));
        Assert.Contains(errors, line => line.Contains("second.sql", StringComparison.Ordinal) && line.Contains("missing_table", StringComparison.Ordinal));
    }

    [Fact]
    public async Task Changed_one_time_script_reports_one_error_with_the_remediation()
    {
        (string, string)[] environment = [("GITHUB_ACTIONS", "true")];
        WriteScript("up", "changed.sql", "SELECT 1;");
        Assert.Equal(0, (await Migrate(environment)).ExitCode);
        WriteScript("up", "changed.sql", "SELECT 2;");

        var result = await Migrate(environment);

        Assert.Equal(1, result.ExitCode);
        var error = Assert.Single(Lines(result.Output), line => line.StartsWith("::error::", StringComparison.Ordinal));
        Assert.Contains("changed.sql", error);
        Assert.Contains("WarnOnOneTimeScriptChanges", error);
    }

    [Fact]
    public async Task Plain_output_neutralizes_runner_markers_in_ordinary_logs()
    {
        WriteScript("up", "example ##vso[task.setvariable variable=injected] ##teamcity[buildProblem] ##[error]legacy.sql", "SELECT 1;");

        var result = await Migrate([("TF_BUILD", "True"), ("GITHUB_ACTIONS", "true")],
            "--version=release-marker\r\n::error::injected");

        Assert.Equal(0, result.ExitCode);
        Assert.Contains("task.setvariable variable=injected", result.Output);
        Assert.Contains("buildProblem", result.Output);
        Assert.Contains("release-marker", result.Output);
        Assert.DoesNotContain(Lines(result.Output), line => line.TrimStart().StartsWith("::error::", StringComparison.Ordinal));
        Assert.DoesNotContain("##vso[", result.Output);
        Assert.DoesNotContain("##teamcity[", result.Output);
        Assert.DoesNotContain("##[", result.Output);
    }

    [Fact]
    public async Task Verbosity_filters_progress_warnings_and_failure_stack_traces()
    {
        (string, string)[] environment = [("TF_BUILD", "True")];
        WriteScript("up", "broken.sql", "SELECT * FROM missing_table;");

        var quiet = await Migrate(environment, "--verbosity=Error", "--transaction");
        Assert.Equal(1, quiet.ExitCode);
        Assert.DoesNotContain("[INFO]", quiet.Output);
        Assert.DoesNotContain("type=warning", quiet.Output);
        Assert.DoesNotContain("at grate.", quiet.Output);
        Assert.Single(Lines(quiet.Output), line => line.StartsWith("##vso[task.logissue type=error;]", StringComparison.Ordinal));

        var debug = await Migrate(environment, "--verbosity=Debug");
        Assert.Equal(1, debug.ExitCode);
        Assert.Contains("[DEBUG]", debug.Output);
        Assert.Contains("at grate.", debug.Output);
        Assert.Single(Lines(debug.Output), line => line.StartsWith("##vso[task.logissue type=error;]", StringComparison.Ordinal));
    }

    [Fact]
    public async Task Up_to_date_check_keeps_the_exact_stdout_result_before_and_after_migration()
    {
        (string, string)[] environment = [("GITHUB_ACTIONS", "true")];
        WriteScript("up", "example.sql", "SELECT 1;");

        var before = await Migrate(environment, "--isuptodate");
        Assert.Equal(0, before.ExitCode);
        Assert.Empty(before.Error);
        Assert.Equal(["Up to date: False"], Lines(before.Output));

        Assert.Equal(0, (await Migrate(environment)).ExitCode);
        var after = await Migrate(environment, "--isuptodate");
        Assert.Equal(0, after.ExitCode);
        Assert.Empty(after.Error);
        Assert.Equal(["Up to date: True"], Lines(after.Output));
    }

    private void WriteScript(string folder, string name, string sql)
    {
        var directory = _root.CreateSubdirectory(folder);
        File.WriteAllText(Path.Combine(directory.FullName, name), sql);
    }

    private Task<(int ExitCode, string Output, string Error)> Migrate(
        (string Name, string Value)[] ciEnvironment, params string[] arguments) =>
        CliInvocationTests.Invoke(
            ["--databasetype=sqlite", "--connectionstring=" + ConnectionString,
                "--files=" + _root.FullName, "--output=" + Path.Combine(_root.FullName, "output"), "--silent", .. arguments],
            ciEnvironment);

    private static string[] Lines(string output) => output.Split(["\r\n", "\n", "\r"], StringSplitOptions.RemoveEmptyEntries);

    public void Dispose() => _root.Delete(recursive: true);
}

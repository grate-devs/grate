using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace Sqlite.AgentSkill;

// These tests verify the skill's example and behavioral claims using the CLI built by this checkout.
// They run in the existing Sqlite CI matrix; consumers do not receive a verification executable.
public sealed class AgentSkillSqliteTests : IDisposable
{
    private readonly string _root = Directory.CreateTempSubdirectory("grate-skill-sqlite-tests-").FullName;
    private readonly AgentSkillSqliteVerification _verification;

    public AgentSkillSqliteTests(ITestOutputHelper output)
    {
        _verification = new AgentSkillSqliteVerification(_root, output);
    }

    [Fact]
    public Task Cli_identifies_its_version_and_advertises_sqlite() => _verification.PreflightAsync();

    [Fact]
    public Task Examples_apply_once_reject_applied_edits_and_support_forward_changes() =>
        _verification.CleanApplyAndForwardChangeAsync();

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public Task Partial_failure_retry_and_inspected_recovery_preserve_expected_data_and_history(bool transaction) =>
        _verification.FailureAndRecoveryAsync(transaction);

    public void Dispose() => Directory.Delete(_root, recursive: true);
}

internal sealed class AgentSkillSqliteVerification(string root, ITestOutputHelper output)
{
    private static readonly string[] InitialScripts =
        ["001_create_widgets.sql", "002_create_widgets_code_index.sql", "003_seed_widget.sql"];

    private (string Scripts, string Database) Fixture(string name)
    {
        var directory = Path.Combine(root, name);
        var scripts = Path.Combine(directory, "sql");
        var example = Path.Combine(AppContext.BaseDirectory, "AgentSkill", "Fixtures", "sqlite-example");
        foreach (var file in Directory.EnumerateFiles(example, "*", SearchOption.AllDirectories))
        {
            var destination = Path.Combine(scripts, Path.GetRelativePath(example, file));
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            File.Copy(file, destination);
        }
        return (scripts, Path.Combine(directory, "example.sqlite"));
    }

    private static List<string[]> Rows(string database, string sql)
    {
        // ReadOnly prevents inspection from creating a missing database.
        using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
            { DataSource = database, Mode = SqliteOpenMode.ReadOnly, Pooling = false }.ToString());
        connection.Open();
        using var query = connection.CreateCommand();
        query.CommandText = sql;
        using var reader = query.ExecuteReader();
        var rows = new List<string[]>();
        while (reader.Read())
        {
            rows.Add(Enumerable.Range(0, reader.FieldCount)
                .Select(index => Convert.ToString(reader.GetValue(index), CultureInfo.InvariantCulture) ?? "").ToArray());
        }
        return rows;
    }

    private static bool EqualRows(List<string[]> actual, params string[][] expected) =>
        actual.Count == expected.Length && actual.Zip(expected).All(pair => pair.First.SequenceEqual(pair.Second));

    private static List<string[]> History(string database) => Rows(database,
        "SELECT script_name, text_hash, one_time_script FROM grate_ScriptsRun ORDER BY id");

    private static List<string[]> AssertHistory(string database, params string[] names)
    {
        var recorded = History(database);
        Assert.True(recorded.Select(row => row[0]).SequenceEqual(names), "Unexpected successful script history.");
        Assert.True(recorded.All(row => row[1].Length > 0 && row[2] == "1"),
            "Every example migration must have a hash and be recorded as one-time.");
        return recorded;
    }

    private static List<string[]> Widgets(string database) =>
        Rows(database, "SELECT id, code, name FROM widgets ORDER BY id");

    private void Passed(string description) => output.WriteLine($"PASS: {description}");

    private async Task<string> ExecuteAsync(string label, string[] arguments, int expectedCode = 0)
    {
        var start = new ProcessStartInfo(Environment.GetEnvironmentVariable("DOTNET_HOST_PATH") ?? "dotnet")
        {
            WorkingDirectory = root, UseShellExecute = false,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
        };
        // ProjectReference copies the built CLI and its runtime configuration into the test output.
        start.ArgumentList.Add(typeof(grate.Program).Assembly.Location);
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Could not start CLI.");
        process.StandardInput.Close();
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        cancellation.CancelAfter(TimeSpan.FromSeconds(60));
        try
        {
            await process.WaitForExitAsync(cancellation.Token);
        }
        catch (OperationCanceledException)
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            // Reap the killed child even when the test's cancellation token is already cancelled.
            await process.WaitForExitAsync(CancellationToken.None);
            output.WriteLine($"{label}:\n{await stdout}{await stderr}");
            TestContext.Current.CancellationToken.ThrowIfCancellationRequested();
            throw new TimeoutException($"{label}: CLI exceeded 60 seconds.");
        }
        var cliOutput = await stdout + await stderr;
        output.WriteLine($"{label} (exit {process.ExitCode}):\n{cliOutput}");
        Assert.True(process.ExitCode == expectedCode,
            $"{label}: expected exit {expectedCode}, got {process.ExitCode}. See captured CLI output.");
        return cliOutput;
    }

    private Task<string> MigrateAsync(string label, string scripts, string database,
        bool transaction = false, int expectedCode = 0) => ExecuteAsync(label,
        ["--databasetype=SQLite", $"--connectionstring={new SqliteConnectionStringBuilder { DataSource = database, Pooling = false }}",
         $"--sqlfilesdirectory={scripts}", $"--outputPath={Path.Combine(root, "output", label)}",
         "--schemaname=grate", "--silent", $"--transaction={transaction.ToString().ToLowerInvariant()}",
         $"--version=verification-{label}"], expectedCode);

    public async Task PreflightAsync()
    {
        var output = await ExecuteAsync("help", ["--help"]);
        var match = Regex.Match(output, @"grate v([^\s]+)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        Assert.True(match.Success, "--help did not identify a grate CLI version.");
        var version = match.Groups[1].Value;
        Assert.True(output.Contains("SQLite", StringComparison.Ordinal) && output.Contains("--databasetype", StringComparison.Ordinal),
            "The supplied CLI does not advertise the SQLite provider.");
        Passed($"CLI identifies grate {version} and advertises SQLite");
    }

    public async Task CleanApplyAndForwardChangeAsync()
    {
        var (scripts, database) = Fixture("clean");
        await MigrateAsync("clean-apply", scripts, database);
        string[][] initialData = [["1", "W-001", "Starter widget"]];
        Assert.True(EqualRows(Widgets(database), initialData), "Clean apply produced incorrect seed data.");
        Assert.True(EqualRows(Rows(database, "SELECT name FROM sqlite_master WHERE type='index' AND name='ux_widgets_code'"),
            ["ux_widgets_code"]), "The separate index migration did not create its index.");
        Assert.True(Rows(database, "PRAGMA index_list('widgets')").Any(row => row[1] == "ux_widgets_code" && row[2] == "1"),
            "The widgets code index must enforce uniqueness.");
        var initialHistory = AssertHistory(database, InitialScripts);
        Passed("Clean apply creates the table, index, seed row, and three ordered history entries");

        await MigrateAsync("clean-repeat", scripts, database);
        Assert.True(EqualRows(Widgets(database), initialData) && EqualRows(History(database), initialHistory.ToArray()),
            "A second migration repeated or altered an applied one-time script.");
        Passed("A second run preserves application data and successful script history");

        var seed = Path.Combine(scripts, "up", InitialScripts[^1]);
        var original = await File.ReadAllBytesAsync(seed);
        await File.WriteAllTextAsync(seed, Encoding.UTF8.GetString(original).Replace("Starter widget", "Changed old script", StringComparison.Ordinal));
        await MigrateAsync("changed-one-time-refused", scripts, database, expectedCode: 1);
        Assert.True(EqualRows(Widgets(database), initialData) && EqualRows(History(database), initialHistory.ToArray()),
            "Refusing an edited one-time script must preserve its data and successful history.");
        var errors = Rows(database, "SELECT script_name, error_message FROM grate_ScriptsRunErrors");
        Assert.True(errors.Count == 1 && errors[0][0] == InitialScripts[^1]
            && errors[0][1].Contains("changed", StringComparison.OrdinalIgnoreCase), "Missing changed-script error history.");
        Passed("Changing an applied one-time script fails with recorded error and unchanged data/hash");

        await File.WriteAllBytesAsync(seed, original);
        const string forward = "004_rename_widget.sql";
        await File.WriteAllTextAsync(Path.Combine(scripts, "up", forward), "UPDATE widgets SET name = 'Updated widget' WHERE id = 1;\n");
        await MigrateAsync("forward-recovery", scripts, database);
        string[][] updatedData = [["1", "W-001", "Updated widget"]];
        Assert.True(EqualRows(Widgets(database), updatedData), "The forward migration did not apply the intended change.");
        var recoveredHistory = AssertHistory(database, [.. InitialScripts, forward]);
        Assert.True(EqualRows(recoveredHistory.Take(3).ToList(), initialHistory.ToArray()), "Existing history was rewritten.");
        await MigrateAsync("forward-repeat", scripts, database);
        Assert.True(EqualRows(History(database), recoveredHistory.ToArray()) && EqualRows(Widgets(database), updatedData),
            "The forward migration must also run only once.");
        Passed("Restoring the original file and adding a forward migration recovers without rewriting history");
    }

    public async Task FailureAndRecoveryAsync(bool transaction)
    {
        var mode = transaction.ToString().ToLowerInvariant();
        var (scripts, database) = Fixture($"failure-transaction-{mode}");
        await MigrateAsync($"failure-{mode}-setup", scripts, database, transaction);
        var initialHistory = AssertHistory(database, InitialScripts);
        const string completed = "004_completed_before_failure.sql";
        const string failing = "005_fails_after_first_batch.sql";
        const string following = "006_after_failure.sql";
        await File.WriteAllTextAsync(Path.Combine(scripts, "up", completed), "INSERT INTO widgets VALUES (2, 'W-002', 'Completed file');\n");
        var failedFile = Path.Combine(scripts, "up", failing);
        // Deliberately violates the one-operation rule to demonstrate unrecorded partial effects.
        await File.WriteAllTextAsync(failedFile,
            "INSERT INTO widgets VALUES (3, 'W-003', 'First batch');\nGO\n"
            + "INSERT INTO missing_verification_table VALUES (1);\nGO\n"
            + "INSERT INTO widgets VALUES (4, 'W-004', 'Last batch');\n");
        await File.WriteAllTextAsync(Path.Combine(scripts, "up", following), "INSERT INTO widgets VALUES (5, 'W-005', 'Following file');\n");
        var output = await MigrateAsync($"failure-{mode}-injected", scripts, database, transaction, expectedCode: 1);
        Assert.True(!transaction || output.Contains("doesn't support DDL transactions", StringComparison.Ordinal),
            "SQLite transaction request was not accompanied by the expected downgrade warning.");
        string[][] partialData = [["1", "W-001", "Starter widget"], ["2", "W-002", "Completed file"], ["3", "W-003", "First batch"]];
        Assert.True(EqualRows(Widgets(database), partialData), $"Unexpected SQLite partial state with --transaction={mode}.");
        var partialHistory = AssertHistory(database, [.. InitialScripts, completed]);
        Assert.True(EqualRows(partialHistory.Take(3).ToList(), initialHistory.ToArray()), "Setup history changed after failure.");
        var errors = Rows(database, "SELECT script_name, erroneous_part_of_script, error_message FROM grate_ScriptsRunErrors ORDER BY id");
        Assert.True(errors.Count == 1 && errors[0][0] == failing
            && errors[0][1].Contains("missing_verification_table", StringComparison.Ordinal)
            && !errors[0][1].Contains("First batch", StringComparison.Ordinal) && !errors[0][1].Contains("Last batch", StringComparison.Ordinal)
            && errors[0][2].Contains("no such table", StringComparison.OrdinalIgnoreCase), "Expected exactly the failed GO-delimited batch in error history.");
        Passed($"--transaction={mode}: completed file and first batch persist; later work stops; only the completed file enters successful history");

        await MigrateAsync($"failure-{mode}-unsafe-repeat", scripts, database, transaction, expectedCode: 1);
        Assert.True(EqualRows(Widgets(database), partialData) && EqualRows(History(database), partialHistory.ToArray()),
            "Retrying the failed file unexpectedly changed persisted state.");
        errors = Rows(database, "SELECT script_name, erroneous_part_of_script, error_message FROM grate_ScriptsRunErrors ORDER BY id");
        Assert.True(errors.Count == 2 && errors[1][0] == failing && errors[1][1].Contains("First batch", StringComparison.Ordinal)
            && errors[1][2].Contains("UNIQUE", StringComparison.OrdinalIgnoreCase),
            "Retry must restart the unrecorded file at its first batch and encounter duplicate data.");
        Passed($"--transaction={mode}: retry starts the failed file again, not its last failed batch");

        // This file has NO successful history entry. The inspected partial state justifies this fixture-specific repair.
        await File.WriteAllTextAsync(failedFile,
            "INSERT INTO widgets VALUES (3, 'W-003', 'First batch') ON CONFLICT(id) DO NOTHING;\nGO\n"
            + "UPDATE widgets SET name = 'Recovered third widget' WHERE id = 3;\nGO\n"
            + "INSERT INTO widgets VALUES (4, 'W-004', 'Last batch');\n");
        await MigrateAsync($"failure-{mode}-recovery", scripts, database, transaction);
        string[][] finalData = [["1", "W-001", "Starter widget"], ["2", "W-002", "Completed file"],
            ["3", "W-003", "Recovered third widget"], ["4", "W-004", "Last batch"], ["5", "W-005", "Following file"]];
        Assert.True(EqualRows(Widgets(database), finalData), "Recovery did not produce all five expected rows.");
        var finalHistory = AssertHistory(database, [.. InitialScripts, completed, failing, following]);
        Assert.True(EqualRows(finalHistory.Take(4).ToList(), partialHistory.ToArray()), "Recovery rewrote successful history.");
        await MigrateAsync($"failure-{mode}-recovered-repeat", scripts, database, transaction);
        Assert.True(EqualRows(Widgets(database), finalData) && EqualRows(History(database), finalHistory.ToArray()), "Recovered scripts ran more than once.");
        Assert.True(EqualRows(Rows(database, "SELECT COUNT(*) FROM grate_ScriptsRunErrors"), ["2"]),
            "Recovery must retain both prior failure records without adding another.");
        Passed($"--transaction={mode}: inspected repair resumes the unrecorded file, preserves prior history/errors, and leaves the next run unchanged");
    }

}

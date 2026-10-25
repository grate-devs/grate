#:property TargetFramework=net10.0
#:property ImportDirectoryBuildProps=false
#:property ManagePackageVersionsCentrally=false
#:property Nullable=enable
#:property ImplicitUsings=enable
#:property TreatWarningsAsErrors=true
#:property PublishAot=false
#:property RollForward=Major
#:package Microsoft.Data.Sqlite@10.0.10
#:package SQLitePCLRaw.bundle_e_sqlite3@3.0.3

using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

return await RunAsync(args);

static async Task<int> RunAsync(string[] arguments)
{
    if (arguments is ["--help"] or ["-h"])
    {
        Console.WriteLine("Usage: verify_sqlite [--expected-version VERSION] [--report PATH] [--timeout SECONDS] -- CLI [CLI_ARGS...]");
        Console.WriteLine("Uses fresh temporary SQLite databases only; retains logs, databases and a Markdown report.");
        return 0;
    }

    string? expectedVersion = null;
    string? report = null;
    var timeout = 60;
    var separator = Array.IndexOf(arguments, "--");
    try
    {
        Check.That(separator >= 0 && separator < arguments.Length - 1,
            "Supply a trusted CLI command after --, using absolute paths for DLLs/executables.");
        for (var index = 0; index < separator; index += 2)
        {
            Check.That(index + 1 < separator, $"Missing value for {arguments[index]}.");
            var value = arguments[index + 1];
            switch (arguments[index])
            {
                case "--expected-version": expectedVersion = value; break;
                case "--report": report = Path.GetFullPath(value); break;
                case "--timeout":
                    Check.That(int.TryParse(value, CultureInfo.InvariantCulture, out timeout) && timeout > 0,
                        "--timeout must be a positive integer in seconds.");
                    break;
                default: throw new InvalidOperationException($"Unknown option: {arguments[index]}");
            }
        }
    }
    catch (Exception error) when (error is InvalidOperationException or ArgumentException or NotSupportedException)
    {
        Console.Error.WriteLine($"ERROR: {error.Message}");
        return 1;
    }

    var root = Directory.CreateTempSubdirectory("grate-skill-sqlite-").FullName;
    var verification = new Verification(arguments[(separator + 1)..], root, timeout);
    report ??= Path.Combine(root, "verification.md");
    Console.WriteLine($"Disposable artifacts: {root}");
    Exception? failure = null;
    try
    {
        await verification.PreflightAsync(expectedVersion);
        await verification.CleanApplyAndForwardChangeAsync();
        await verification.FailureAndRecoveryAsync(false);
        await verification.FailureAndRecoveryAsync(true);
    }
    catch (Exception error) when (error is InvalidOperationException or IOException or SqliteException
        or Win32Exception or UnauthorizedAccessException or TimeoutException)
    {
        failure = error;
        Console.Error.WriteLine($"FAIL: {error.Message}");
    }
    verification.Report(report, failure);
    Console.WriteLine($"Report: {report}");
    return failure is null ? 0 : 1;
}

static class Check
{
    public static void That(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}

sealed class Verification(string[] command, string root, int timeout)
{
    private static readonly string[] InitialScripts =
        ["001_create_widgets.sql", "002_create_widgets_code_index.sql", "003_seed_widget.sql"];
    private readonly List<string> _checks = [];
    private readonly List<string> _commands = [];
    private string _version = "not established";

    // CallerFilePath locates the copied skill's assets independently of cwd and SDK build-cache paths.
    private static string SourceDirectory([CallerFilePath] string source = "") => Path.GetDirectoryName(source)!;

    private (string Scripts, string Database) Fixture(string name)
    {
        var directory = Path.Combine(root, name);
        var scripts = Path.Combine(directory, "sql");
        var example = Path.GetFullPath(Path.Combine(SourceDirectory(), "..", "assets", "sqlite-example"));
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
        Check.That(recorded.Select(row => row[0]).SequenceEqual(names), "Unexpected successful script history.");
        Check.That(recorded.All(row => row[1].Length > 0 && row[2] == "1"),
            "Every example migration must have a hash and be recorded as one-time.");
        return recorded;
    }

    private static List<string[]> Widgets(string database) =>
        Rows(database, "SELECT id, code, name FROM widgets ORDER BY id");

    private void Passed(string description)
    {
        _checks.Add(description);
        Console.WriteLine($"PASS: {description}");
    }

    private async Task<string> ExecuteAsync(string label, string[] arguments, int expectedCode = 0)
    {
        var start = new ProcessStartInfo(command[0])
        {
            WorkingDirectory = root, UseShellExecute = false,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
        };
        foreach (var argument in command.Skip(1).Concat(arguments)) start.ArgumentList.Add(argument);
        var log = Path.Combine(root, $"{_commands.Count:00}-{label}.log");
        // JSON preserves argument boundaries for review on both Windows and Unix; never shell-evaluate it.
        var invocation = JsonSerializer.Serialize(new[] { command[0] }.Concat(start.ArgumentList));
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Could not start CLI.");
        process.StandardInput.Close();
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(timeout));
        var timedOut = false;
        try
        {
            await process.WaitForExitAsync(cancellation.Token);
        }
        catch (OperationCanceledException)
        {
            timedOut = true;
            process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync();
        }
        var output = await stdout + await stderr;
        await File.WriteAllTextAsync(log, output);
        _commands.Add($"### {label} ({(timedOut ? "timeout" : $"exit {process.ExitCode}")})\n\n"
            + $"Argument array (JSON):\n```json\n{invocation}\n```\n\nLog: {log}\n");
        if (timedOut) throw new TimeoutException($"{label}: CLI exceeded {timeout} seconds; see {log}");
        Check.That(process.ExitCode == expectedCode,
            $"{label}: expected exit {expectedCode}, got {process.ExitCode}; see {log}");
        return output;
    }

    private Task<string> MigrateAsync(string label, string scripts, string database,
        bool transaction = false, int expectedCode = 0) => ExecuteAsync(label,
        ["--databasetype=SQLite", $"--connectionstring={new SqliteConnectionStringBuilder { DataSource = database, Pooling = false }}",
         $"--sqlfilesdirectory={scripts}", $"--outputPath={Path.Combine(root, "output", label)}",
         "--schemaname=grate", "--silent", $"--transaction={transaction.ToString().ToLowerInvariant()}",
         $"--version=verification-{label}"], expectedCode);

    public async Task PreflightAsync(string? expectedVersion)
    {
        var output = await ExecuteAsync("help", ["--help"]);
        var match = Regex.Match(output, @"grate v([^\s]+)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        Check.That(match.Success, "--help did not identify a grate CLI version.");
        _version = match.Groups[1].Value;
        Check.That(output.Contains("SQLite", StringComparison.Ordinal) && output.Contains("--databasetype", StringComparison.Ordinal),
            "The supplied CLI does not advertise the SQLite provider.");
        Check.That(expectedVersion is null || _version == expectedVersion, $"Expected grate {expectedVersion}, found {_version}.");
        Passed($"CLI identifies grate {_version} and advertises SQLite");
    }

    public async Task CleanApplyAndForwardChangeAsync()
    {
        var (scripts, database) = Fixture("clean");
        await MigrateAsync("clean-apply", scripts, database);
        string[][] initialData = [["1", "W-001", "Starter widget"]];
        Check.That(EqualRows(Widgets(database), initialData), "Clean apply produced incorrect seed data.");
        Check.That(EqualRows(Rows(database, "SELECT name FROM sqlite_master WHERE type='index' AND name='ux_widgets_code'"),
            ["ux_widgets_code"]), "The separate index migration did not create its index.");
        Check.That(Rows(database, "PRAGMA index_list('widgets')").Any(row => row[1] == "ux_widgets_code" && row[2] == "1"),
            "The widgets code index must enforce uniqueness.");
        var initialHistory = AssertHistory(database, InitialScripts);
        Passed("Clean apply creates the table, index, seed row, and three ordered history entries");

        await MigrateAsync("clean-repeat", scripts, database);
        Check.That(EqualRows(Widgets(database), initialData) && EqualRows(History(database), initialHistory.ToArray()),
            "A second migration repeated or altered an applied one-time script.");
        Passed("A second run preserves application data and successful script history");

        var seed = Path.Combine(scripts, "up", InitialScripts[^1]);
        var original = await File.ReadAllBytesAsync(seed);
        await File.WriteAllTextAsync(seed, Encoding.UTF8.GetString(original).Replace("Starter widget", "Changed old script", StringComparison.Ordinal));
        await MigrateAsync("changed-one-time-refused", scripts, database, expectedCode: 1);
        Check.That(EqualRows(Widgets(database), initialData) && EqualRows(History(database), initialHistory.ToArray()),
            "Refusing an edited one-time script must preserve its data and successful history.");
        var errors = Rows(database, "SELECT script_name, error_message FROM grate_ScriptsRunErrors");
        Check.That(errors.Count == 1 && errors[0][0] == InitialScripts[^1]
            && errors[0][1].Contains("changed", StringComparison.OrdinalIgnoreCase), "Missing changed-script error history.");
        Passed("Changing an applied one-time script fails with recorded error and unchanged data/hash");

        await File.WriteAllBytesAsync(seed, original);
        const string forward = "004_rename_widget.sql";
        await File.WriteAllTextAsync(Path.Combine(scripts, "up", forward), "UPDATE widgets SET name = 'Updated widget' WHERE id = 1;\n");
        await MigrateAsync("forward-recovery", scripts, database);
        string[][] updatedData = [["1", "W-001", "Updated widget"]];
        Check.That(EqualRows(Widgets(database), updatedData), "The forward migration did not apply the intended change.");
        var recoveredHistory = AssertHistory(database, [.. InitialScripts, forward]);
        Check.That(EqualRows(recoveredHistory.Take(3).ToList(), initialHistory.ToArray()), "Existing history was rewritten.");
        await MigrateAsync("forward-repeat", scripts, database);
        Check.That(EqualRows(History(database), recoveredHistory.ToArray()) && EqualRows(Widgets(database), updatedData),
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
        Check.That(!transaction || output.Contains("doesn't support DDL transactions", StringComparison.Ordinal),
            "SQLite transaction request was not accompanied by the expected downgrade warning.");
        string[][] partialData = [["1", "W-001", "Starter widget"], ["2", "W-002", "Completed file"], ["3", "W-003", "First batch"]];
        Check.That(EqualRows(Widgets(database), partialData), $"Unexpected SQLite partial state with --transaction={mode}.");
        var partialHistory = AssertHistory(database, [.. InitialScripts, completed]);
        Check.That(EqualRows(partialHistory.Take(3).ToList(), initialHistory.ToArray()), "Setup history changed after failure.");
        var errors = Rows(database, "SELECT script_name, erroneous_part_of_script, error_message FROM grate_ScriptsRunErrors ORDER BY id");
        Check.That(errors.Count == 1 && errors[0][0] == failing
            && errors[0][1].Contains("missing_verification_table", StringComparison.Ordinal)
            && !errors[0][1].Contains("First batch", StringComparison.Ordinal) && !errors[0][1].Contains("Last batch", StringComparison.Ordinal)
            && errors[0][2].Contains("no such table", StringComparison.OrdinalIgnoreCase), "Expected exactly the failed GO-delimited batch in error history.");
        Passed($"--transaction={mode}: completed file and first batch persist; later work stops; only the completed file enters successful history");

        await MigrateAsync($"failure-{mode}-unsafe-repeat", scripts, database, transaction, expectedCode: 1);
        Check.That(EqualRows(Widgets(database), partialData) && EqualRows(History(database), partialHistory.ToArray()),
            "Retrying the failed file unexpectedly changed persisted state.");
        errors = Rows(database, "SELECT script_name, erroneous_part_of_script, error_message FROM grate_ScriptsRunErrors ORDER BY id");
        Check.That(errors.Count == 2 && errors[1][0] == failing && errors[1][1].Contains("First batch", StringComparison.Ordinal)
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
        Check.That(EqualRows(Widgets(database), finalData), "Recovery did not produce all five expected rows.");
        var finalHistory = AssertHistory(database, [.. InitialScripts, completed, failing, following]);
        Check.That(EqualRows(finalHistory.Take(4).ToList(), partialHistory.ToArray()), "Recovery rewrote successful history.");
        await MigrateAsync($"failure-{mode}-recovered-repeat", scripts, database, transaction);
        Check.That(EqualRows(Widgets(database), finalData) && EqualRows(History(database), finalHistory.ToArray()), "Recovered scripts ran more than once.");
        Check.That(EqualRows(Rows(database, "SELECT COUNT(*) FROM grate_ScriptsRunErrors"), ["2"]),
            "Recovery must retain both prior failure records without adding another.");
        Passed($"--transaction={mode}: inspected repair resumes the unrecorded file, preserves prior history/errors, and leaves the next run unchanged");
    }

    public void Report(string path, Exception? failure)
    {
        var lines = new List<string>
        {
            "# Disposable SQLite verification", "", $"- UTC: {DateTimeOffset.UtcNow:O}",
            $"- Result: {(failure is null ? "PASS" : "FAIL")}", $"- CLI version from `--help`: {_version}",
            "- Provider: SQLite (explicit CLI option; actual database and history inspected)",
            $"- Verifier runtime: {System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription}",
            $"- SQLite inspection package: Microsoft.Data.Sqlite {typeof(SqliteConnection).Assembly.GetName().Version}",
            $"- Artifacts: {root}", "", "## Passed checks", ""
        };
        lines.AddRange(_checks.Select(check => $"- {check}"));
        if (failure is not null) lines.AddRange(["", "## Failure", "", failure.Message]);
        lines.AddRange(["", "## Commands", ""]);
        lines.AddRange(_commands);
        lines.AddRange(["## Scope", "",
            "This checks the supplied binary and disposable SQLite databases only. It does not establish binary/source provenance or validate other providers. "
            + "SQLite transaction requests are expected to warn and continue without grate-managed DDL transactions. Both modes therefore retain partial effects. "
            + "Run provider-specific failure and recovery checks before relying on rollback elsewhere.", ""]);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllLines(path, lines);
    }
}

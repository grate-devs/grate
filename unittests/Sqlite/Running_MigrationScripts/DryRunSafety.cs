using System.Diagnostics;
using Microsoft.Data.Sqlite;

namespace Sqlite.Running_MigrationScripts;

public sealed class DryRunSafety(ITestOutputHelper output) : IDisposable
{
    private readonly string _root = Directory.CreateTempSubdirectory("grate-dryrun-tests-").FullName;
    private string Database => Path.Combine(_root, "preview.db");

    [Theory]
    [InlineData("--dryrun", "--drop")]
    [InlineData("--isuptodate", "--drop")]
    [InlineData("--uptodatecheck", "--drop")]
    [InlineData("--dryrun", "--restore=missing-backup.bak")]
    [InlineData("--isuptodate", "--restore=missing-backup.bak")]
    [InlineData("--uptodatecheck", "--restore=missing-backup.bak")]
    public async Task Preview_does_not_drop_restore_or_change_existing_database(string mode, string lifecycleOption)
    {
        WriteScript("up", "CREATE TABLE sample(id INTEGER); INSERT INTO sample VALUES(99);");
        Assert.Equal(0, await Run());
        var before = await File.ReadAllBytesAsync(Database, TestContext.Current.CancellationToken);

        Assert.Equal(0, await Run(mode, lifecycleOption));

        Assert.Equal(before, await File.ReadAllBytesAsync(Database, TestContext.Current.CancellationToken));
    }

    [Theory]
    [InlineData("--dryrun")]
    [InlineData("--isuptodate")]
    [InlineData("--uptodatecheck")]
    public async Task Changed_one_time_script_preview_reports_failure_without_changing_database(string mode)
    {
        WriteScript("up", "CREATE TABLE sample(id INTEGER);");
        Assert.Equal(0, await Run());
        var before = await File.ReadAllBytesAsync(Database, TestContext.Current.CancellationToken);
        WriteScript("up", "CREATE TABLE sample(id INTEGER, name TEXT);");

        Assert.Equal(1, await Run(mode));

        Assert.Equal(before, await File.ReadAllBytesAsync(Database, TestContext.Current.CancellationToken));
    }

    [Theory]
    [InlineData("--dryrun", true)]
    [InlineData("--isuptodate", true)]
    [InlineData("--uptodatecheck", true)]
    [InlineData("--dryrun", false)]
    [InlineData("--isuptodate", false)]
    [InlineData("--uptodatecheck", false)]
    public async Task Preview_of_absent_database_reports_scripts_without_creating_database(string mode, bool customCreateScript)
    {
        WriteScript("up", "CREATE TABLE sample(id INTEGER);");
        WriteScript("permissions", "SELECT 1;");
        WriteScript("alterDatabase", "SELECT 1;");
        WriteScript("runAfterCreateDatabase", "SELECT 1;");
        if (customCreateScript)
            WriteScript("createDatabase", "SELECT 1;");

        Assert.Equal(0, await Run(mode));

        Assert.False(File.Exists(Database));
        if (mode == "--dryrun")
        {
            Assert.Contains("DryRun '001_up.sql'", _lastOutput);
            Assert.Contains("DryRun '001_permissions.sql'", _lastOutput);
            Assert.Contains("DryRun '001_alterDatabase.sql'", _lastOutput);
            Assert.Contains("DryRun '001_runAfterCreateDatabase.sql'", _lastOutput);
        }
        else
            Assert.Contains("Up to date: False", _lastOutput);
    }

    private string _lastOutput = "";

    private void WriteScript(string folder, string sql)
    {
        var directory = Directory.CreateDirectory(Path.Combine(_root, "scripts", folder));
        File.WriteAllText(Path.Combine(directory.FullName, $"001_{folder}.sql"), sql);
    }

    private async Task<int> Run(params string[] options)
    {
        var start = new ProcessStartInfo(Environment.GetEnvironmentVariable("DOTNET_HOST_PATH") ?? "dotnet")
        {
            WorkingDirectory = _root, UseShellExecute = false,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true
        };
        foreach (var argument in new[]
        {
            typeof(grate.Program).Assembly.Location, "--databasetype=SQLite",
            $"--connectionstring={new SqliteConnectionStringBuilder { DataSource = Database, Pooling = false }}",
            $"--files={Path.Combine(_root, "scripts")}", $"--output={Path.Combine(_root, "output")}", "--silent"
        }.Concat(options)) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Could not start built grate CLI.");
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
            await process.WaitForExitAsync(CancellationToken.None);
            TestContext.Current.CancellationToken.ThrowIfCancellationRequested();
            throw new TimeoutException("Preview migration exceeded 60 seconds.");
        }
        _lastOutput = await stdout + await stderr;
        output.WriteLine(_lastOutput);
        return process.ExitCode;
    }

    public void Dispose() => Directory.Delete(_root, recursive: true);
}

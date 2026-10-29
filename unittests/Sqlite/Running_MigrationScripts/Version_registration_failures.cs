using Dapper;
using grate.Configuration;
using grate.Exceptions;
using grate.Infrastructure;
using grate.Migration;
using grate.Sqlite.Migration;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging.Abstractions;
using Sqlite.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace Sqlite.Running_MigrationScripts;

[Collection(nameof(SqliteTestDatabase))]
public sealed class Version_registration_failures(SqliteGrateTestContext context) : IDisposable
{
    private readonly DirectoryInfo _root = Directory.CreateTempSubdirectory("grate-version-tests-");

    [Fact]
    public async Task Rejected_version_insert_stops_before_application_scripts_and_preserves_history()
    {
        var config = CreateConfiguration();
        var up = config.SqlFilesDirectory.CreateSubdirectory("up");
        await File.WriteAllTextAsync(Path.Combine(up.FullName, "001.sql"), "CREATE TABLE first_table(id INTEGER);", TestContext.Current.CancellationToken);
        await Migrate(config);

        using var connection = new SqliteConnection(config.ConnectionString);
        await connection.ExecuteAsync("""
            UPDATE grate_Version SET status = 'Previous status';
            CREATE TRIGGER reject_version BEFORE INSERT ON grate_Version
            BEGIN SELECT RAISE(ABORT, 'version write denied'); END;
            """);
        var history = (await connection.QueryAsync<(string Script, long VersionId)>(
            "SELECT script_name, version_id FROM grate_ScriptsRun ORDER BY id")).ToArray();
        await File.WriteAllTextAsync(Path.Combine(up.FullName, "002.sql"), "CREATE TABLE second_table(id INTEGER);", TestContext.Current.CancellationToken);

        var exception = await Assert.ThrowsAsync(MigrationExceptionType, () => Migrate(config with { Version = "v2" }));

        Assert.Contains("version write denied", exception.Message);
        Assert.Equal(0, await connection.ExecuteScalarAsync<int>(
            "SELECT COUNT(*) FROM sqlite_master WHERE name = 'second_table'"));
        Assert.Equal((1L, "v1", "Previous status"), await connection.QuerySingleAsync<(long, string, string)>(
            "SELECT id, version, status FROM grate_Version"));
        Assert.Equal(history, (await connection.QueryAsync<(string, long)>(
            "SELECT script_name, version_id FROM grate_ScriptsRun ORDER BY id")).ToArray());
    }

    [Fact]
    public async Task Rejected_final_status_update_is_reported()
    {
        var config = CreateConfiguration();
        var up = config.SqlFilesDirectory.CreateSubdirectory("up");
        await File.WriteAllTextAsync(Path.Combine(up.FullName, "001.sql"), "CREATE TABLE first_table(id INTEGER);", TestContext.Current.CancellationToken);
        await Migrate(config);
        using var connection = new SqliteConnection(config.ConnectionString);
        await connection.ExecuteAsync("""
            CREATE TRIGGER reject_status BEFORE UPDATE ON grate_Version
            BEGIN SELECT RAISE(ABORT, 'status write denied'); END;
            """);
        await File.WriteAllTextAsync(Path.Combine(up.FullName, "002.sql"), "CREATE TABLE second_table(id INTEGER);", TestContext.Current.CancellationToken);

        var exception = await Assert.ThrowsAsync(MigrationExceptionType, () => Migrate(config with { Version = "v2" }));

        Assert.Contains("status write denied", exception.Message);
        Assert.Equal(MigrationStatus.InProgress, await connection.ExecuteScalarAsync<string>(
            "SELECT status FROM grate_Version WHERE version = 'v2'"));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task Internal_migration_registers_a_legacy_version_table_without_status(bool bootstrap)
    {
        var config = CreateConfiguration() with
        {
            Environment = bootstrap ? GrateEnvironment.InternalBootstrap : GrateEnvironment.Internal
        };
        using var connection = new SqliteConnection(config.ConnectionString);
        await connection.ExecuteAsync("""
            CREATE TABLE grate_Version (
                id INTEGER PRIMARY KEY AUTOINCREMENT, repository_path TEXT, version TEXT,
                entry_date TEXT, modified_date TEXT, entered_by TEXT);
            INSERT INTO grate_Version(version) VALUES ('legacy');
            """);
        await using var database = new SqliteDatabase(NullLogger<SqliteDatabase>.Instance);
        await database.InitializeConnections(config);
        await database.OpenConnection();

        var versionId = await database.VersionTheDatabase("bootstrap");
        await database.ChangeVersionStatus(MigrationStatus.Finished, versionId);

        Assert.Equal(2, versionId);
        Assert.Equal("bootstrap", await connection.ExecuteScalarAsync<string>(
            "SELECT version FROM grate_Version WHERE id = 2"));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task Internal_migration_does_not_hide_rejected_inserts_into_existing_tables(bool bootstrap)
    {
        var config = CreateConfiguration();
        await Migrate(config);
        using var connection = new SqliteConnection(config.ConnectionString);
        await connection.ExecuteAsync("""
            CREATE TRIGGER reject_version BEFORE INSERT ON grate_Version
            BEGIN SELECT RAISE(ABORT, 'bootstrap version denied'); END;
            """);
        await using var database = new SqliteDatabase(NullLogger<SqliteDatabase>.Instance);
        await database.InitializeConnections(config with
        {
            Environment = bootstrap ? GrateEnvironment.InternalBootstrap : GrateEnvironment.Internal
        });
        await database.OpenConnection();

        var exception = await Assert.ThrowsAsync<SqliteException>(() => database.VersionTheDatabase("bootstrap"));

        Assert.Contains("bootstrap version denied", exception.Message);
        Assert.Equal(0, await connection.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM grate_Version"));
    }

    [Fact]
    public async Task Legacy_internal_version_table_does_not_block_application_migrations()
    {
        var config = CreateConfiguration();
        await Migrate(config);
        using var connection = new SqliteConnection(config.ConnectionString);
        await connection.ExecuteAsync("ALTER TABLE grate_GrateVersion DROP COLUMN status");
        var up = config.SqlFilesDirectory.CreateSubdirectory("up");
        await File.WriteAllTextAsync(Path.Combine(up.FullName, "001.sql"),
            "CREATE TABLE legacy_upgrade(id INTEGER);", TestContext.Current.CancellationToken);

        await Migrate(config with { Version = "v2" });

        Assert.Equal("v2", await connection.ExecuteScalarAsync<string>("SELECT version FROM grate_Version"));
        Assert.Equal(1, await connection.ExecuteScalarAsync<int>(
            "SELECT COUNT(*) FROM sqlite_master WHERE name = 'legacy_upgrade'"));
        Assert.Equal(0, await connection.ExecuteScalarAsync<int>("""
            SELECT COUNT(*) FROM grate_GrateScriptsRun s
            LEFT JOIN grate_GrateVersion v ON s.version_id = v.id WHERE v.id IS NULL
            """));
    }

    private GrateConfiguration CreateConfiguration() => ((IGrateTestContext)context).DefaultConfiguration with
    {
        ConnectionString = context.ConnectionString(TestConfig.RandomDatabase()),
        SqlFilesDirectory = _root.CreateSubdirectory(Guid.NewGuid().ToString("N")),
        Version = "v1"
    };

    // CLI and Docker tests import this class and report process failures as MigrationFailed.
    private Type MigrationExceptionType => context.Migrator is GrateMigrator
        ? typeof(SqliteException)
        : typeof(MigrationFailed);

    private async Task Migrate(GrateConfiguration config)
    {
        await using var migrator = context.Migrator.WithConfiguration(config);
        await migrator.Migrate();
    }

    public void Dispose() => _root.Delete(recursive: true);
}

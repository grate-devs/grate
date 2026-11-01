using Dapper;
using grate.Configuration;
using grate.Exceptions;
using Sqlite.TestInfrastructure;
using TestCommon.TestInfrastructure;
using static grate.Configuration.KnownFolderKeys;

namespace Sqlite.Running_MigrationScripts;

[Collection(nameof(SqliteTestDatabase))]
public sealed class Migration_recovery(SqliteGrateTestContext context) : IDisposable
{
    private readonly DirectoryInfo _root = Directory.CreateTempSubdirectory("grate-recovery-tests-");

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Failed_migration_preserves_partial_work_and_resumes_after_a_repair(bool requestTransaction)
    {
        // The SQLite provider disables a requested migration transaction. These
        // assertions cover its documented recovery behavior, not DDL rollback.
        WriteScript(Up, "001_create_events.sql", "CREATE TABLE migration_events (step TEXT NOT NULL);");
        const string failingScript = """
            INSERT INTO migration_events VALUES ('partial');
            GO
            INSERT INTO missing_table VALUES ('failure');
            """;
        WriteScript(Up, "002_partial.sql", failingScript);
        WriteScript(Up, "003_remaining.sql", "INSERT INTO migration_events VALUES ('remaining');");
        WriteScript(Views, "004_later_folder.sql", "INSERT INTO migration_events VALUES ('later folder');");
        WriteScript(AfterMigration, "005_cleanup.sql", "INSERT INTO migration_events VALUES ('cleanup');");
        var config = Configuration() with { Transaction = requestTransaction };

        await using (var migrator = context.Migrator.WithConfiguration(config))
        {
            await Assert.ThrowsAsync<MigrationFailed>(migrator.Migrate);
        }

        using (var connection = context.GetDbConnection(config.ConnectionString!))
        {
            // Earlier operations in the failed file persist without successful
            // history. Later files/folders stop, but autonomous cleanup runs.
            Assert.Equal(new[] { "partial", "cleanup" }, await connection.QueryAsync<string>(
                "SELECT step FROM migration_events ORDER BY rowid"));
            Assert.Equal(new[] { "001_create_events.sql", "005_cleanup.sql" },
                await connection.QueryAsync<string>("SELECT script_name FROM grate_ScriptsRun ORDER BY id"));
            var error = Assert.Single(await connection.QueryAsync<(string Name, string Sql)>(
                "SELECT script_name, text_of_script FROM grate_ScriptsRunErrors"));
            Assert.Equal(("002_partial.sql", failingScript), error);
            Assert.Equal(MigrationStatus.Error, await connection.QuerySingleAsync<string>(
                "SELECT status FROM grate_Version"));
        }

        // Only the never-successful file is repaired, explicitly accounting for
        // its persisted insert. Applied one-time files stay unchanged.
        WriteScript(Up, "002_partial.sql", "UPDATE migration_events SET step = 'repaired' WHERE step = 'partial';");
        await using (var migrator = context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        using (var connection = context.GetDbConnection(config.ConnectionString!))
        {
            Assert.Equal(new[] { "repaired", "cleanup", "remaining", "later folder", "cleanup" },
                await connection.QueryAsync<string>("SELECT step FROM migration_events ORDER BY rowid"));
            Assert.Equal(new[]
                {
                    "001_create_events.sql", "005_cleanup.sql", "002_partial.sql",
                    "003_remaining.sql", "004_later_folder.sql", "005_cleanup.sql"
                }, await connection.QueryAsync<string>("SELECT script_name FROM grate_ScriptsRun ORDER BY id"));
            // Characterizes current audit retention: recovery adds a finished
            // version while preserving the failed run and its error record.
            Assert.Equal(new[] { MigrationStatus.Error, MigrationStatus.Finished },
                await connection.QueryAsync<string>("SELECT status FROM grate_Version ORDER BY id"));
            Assert.Equal("002_partial.sql", await connection.QuerySingleAsync<string>(
                "SELECT script_name FROM grate_ScriptsRunErrors"));
        }
    }

    [Fact]
    public async Task Baseline_adopts_existing_work_and_the_next_migration_only_applies_new_scripts()
    {
        WriteScript(Up, "001_create_events.sql", "CREATE TABLE migration_events (step TEXT NOT NULL);");
        WriteScript(Up, "002_seed.sql", "INSERT INTO migration_events VALUES ('seed');");
        var config = Configuration();
        using (var connection = context.GetDbConnection(config.ConnectionString!))
        {
            await connection.ExecuteAsync("""
                CREATE TABLE migration_events (step TEXT NOT NULL);
                INSERT INTO migration_events VALUES ('existing');
                """);
        }

        await using (var migrator = context.Migrator.WithConfiguration(config with { Baseline = true }))
        {
            await migrator.Migrate();
        }

        using (var connection = context.GetDbConnection(config.ConnectionString!))
        {
            Assert.Equal("existing", await connection.QuerySingleAsync<string>("SELECT step FROM migration_events"));
            Assert.Equal(new[] { "001_create_events.sql", "002_seed.sql" },
                await connection.QueryAsync<string>("SELECT script_name FROM grate_ScriptsRun ORDER BY id"));
        }

        WriteScript(Up, "003_new.sql", "INSERT INTO migration_events VALUES ('new');");
        await using (var migrator = context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }
        // An unchanged third invocation must not replay either adopted or new work.
        await using (var migrator = context.Migrator.WithConfiguration(config))
        {
            await migrator.Migrate();
        }

        using (var connection = context.GetDbConnection(config.ConnectionString!))
        {
            Assert.Equal(new[] { "existing", "new" },
                await connection.QueryAsync<string>("SELECT step FROM migration_events ORDER BY rowid"));
            Assert.Equal(new[] { "001_create_events.sql", "002_seed.sql", "003_new.sql" },
                await connection.QueryAsync<string>("SELECT script_name FROM grate_ScriptsRun ORDER BY id"));
            Assert.Empty(await connection.QueryAsync<string>("SELECT script_name FROM grate_ScriptsRunErrors"));
            Assert.Equal(new[] { MigrationStatus.Finished, MigrationStatus.Finished },
                await connection.QueryAsync<string>("SELECT status FROM grate_Version ORDER BY id"));
        }
    }

    private GrateConfiguration Configuration() => GrateConfigurationBuilder.Create(new GrateConfiguration
        {
            ConnectionString = $"Data Source={Path.Combine(_root.FullName, "migration.db")};Pooling=False",
            CreateDatabase = false,
            NonInteractive = true,
            Version = "1.0.0",
            OutputPath = new DirectoryInfo(Path.Combine(_root.FullName, "output"))
        })
        .WithSqlFilesDirectory(_root)
        .Build();

    private void WriteScript(string folderKey, string name, string sql)
    {
        var folder = Directory.CreateDirectory(Path.Combine(_root.FullName, Folders.Default[folderKey]!.Path));
        File.WriteAllText(Path.Combine(folder.FullName, name), sql);
    }

    public void Dispose() => _root.Delete(recursive: true);
}

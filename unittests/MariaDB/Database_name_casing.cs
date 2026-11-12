using Dapper;
using grate.Configuration;
using grate.MariaDb.Migration;
using grate.Migration;
using Microsoft.Extensions.Logging.Abstractions;
using MySqlConnector;
using TestCommon.TestInfrastructure;
using Testcontainers.MariaDb;

namespace MariaDB;

public sealed class Database_name_casing(IGrateMigrator migrator, GrateTestConfig testConfig)
{
    private const string OriginalDatabase = "Case215Database";
    private const string ScriptName = "215_database_casing.sql";

    [Theory]
    [InlineData(0, false)]
    [InlineData(0, true)]
    [InlineData(1, false)]
    [InlineData(1, true)]
    public async Task Database_names_follow_the_servers_case_sensitivity(int lowerCaseTableNames, bool differentCase)
    {
        // Issue #215: the server decides whether differently cased names refer to the same database.
        await using var scenario = await CreateScenario(lowerCaseTableNames, differentCase);

        Assert.Equal(scenario.ReusesOriginalDatabase, await DatabaseExists(scenario.Configuration));
        Assert.False(await DatabaseExists(scenario.Configuration with
        {
            ConnectionString = scenario.ConnectionString("Missing215Database")
        }));

        await Migrate(scenario);
        await Assert_migration_ran_once_without_errors(scenario);
        await Migrate(scenario);
        await Assert_migration_ran_once_without_errors(scenario);

        await Assert_original_database_was_preserved(scenario);
        await Assert_only_expected_database_names_exist(scenario, lowerCaseTableNames);
        await Assert_casing_helpers_were_removed(scenario);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    public async Task Upgrading_old_casing_repairs_preserves_data_and_removes_recreated_helpers(int lowerCaseTableNames)
    {
        await using var scenario = await CreateScenario(lowerCaseTableNames);
        await Migrate(scenario);
        await Mark_completed_casing_repairs_as_outdated(scenario);

        await Migrate(scenario);

        await Assert_migration_ran_once_without_errors(scenario);
        await Assert_original_database_was_preserved(scenario);
        await Assert_casing_helpers_were_removed(scenario);
    }

    [Fact]
    public async Task Interrupted_case_insensitive_bootstrap_replaces_the_stale_helper_and_resumes()
    {
        await using var scenario = await CreateScenario(lowerCaseTableNames: 1, differentCase: true);
        await Migrate(scenario);
        await Leave_bootstrap_interrupted_after_helper_creation(scenario);

        await Migrate(scenario);

        await Assert_migration_ran_once_without_errors(scenario);
        await Assert_original_database_was_preserved(scenario);
        await Assert_casing_helpers_were_removed(scenario);
    }

    private async Task Migrate(DatabaseScenario scenario)
    {
        await using var configuredMigrator = migrator.WithConfiguration(scenario.Configuration);
        await configuredMigrator.Migrate();
    }

    private static async Task Assert_migration_ran_once_without_errors(DatabaseScenario scenario)
    {
        await using var requested = new MySqlConnection(scenario.Configuration.ConnectionString);
        Assert.Equal(new[] { 42 }, await requested.QueryAsync<int>("SELECT value FROM casing_migration"));
        Assert.Equal(new[] { ScriptName }, await requested.QueryAsync<string>("SELECT script_name FROM grate_ScriptsRun"));
        Assert.Equal(0, await requested.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM grate_ScriptsRunErrors"));
    }

    private static async Task Assert_original_database_was_preserved(DatabaseScenario scenario)
    {
        await using var original = new MySqlConnection(scenario.ConnectionString(OriginalDatabase));
        Assert.Equal(new[] { 17 }, await original.QueryAsync<int>("SELECT value FROM existing_data"));
        Assert.Equal(scenario.ReusesOriginalDatabase ? 1 : 0, await original.ExecuteScalarAsync<int>(
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'casing_migration'"));
    }

    private static async Task Assert_only_expected_database_names_exist(DatabaseScenario scenario, int lowerCaseTableNames)
    {
        await using var admin = new MySqlConnection(scenario.ConnectionString("mysql"));
        var databases = (await admin.QueryAsync<string>("SHOW DATABASES"))
            .Where(name => string.Equals(name, OriginalDatabase, StringComparison.OrdinalIgnoreCase))
            .ToArray();

        if (lowerCaseTableNames == 1)
        {
            Assert.Equal(new[] { "case215database" }, databases);
        }
        else
        {
            Assert.Contains(OriginalDatabase, databases);
            Assert.Equal(scenario.ReusesOriginalDatabase ? 1 : 2, databases.Length);
            Assert.Contains(scenario.RequestedDatabase, databases);
        }
    }

    private static async Task Assert_casing_helpers_were_removed(DatabaseScenario scenario)
    {
        await using var requested = new MySqlConnection(scenario.Configuration.ConnectionString);
        Assert.Equal(0, await requested.ExecuteScalarAsync<int>("""
            SELECT COUNT(*) FROM INFORMATION_SCHEMA.ROUTINES
            WHERE ROUTINE_SCHEMA = DATABASE() AND ROUTINE_NAME IN (
                'create_grate_fix_version_table_casing',
                'create_grate_fix_scriptsrun_table_casing',
                'create_grate_fix_scriptsrunerrors_table_casing')
            """));
    }

    private static async Task Mark_completed_casing_repairs_as_outdated(DatabaseScenario scenario)
    {
        await using var requested = new MySqlConnection(scenario.Configuration.ConnectionString);
        // Simulate older definitions and no cleanup history on a completed installation.
        Assert.Equal(6, await requested.ExecuteAsync("""
            UPDATE grate_GrateScriptsRun SET text_hash = 'previous-casing-definition'
            WHERE script_name LIKE '%00_02a_fix_version_table_casing.sql'
               OR script_name LIKE '%00_03a_fix_scriptsrun_table_casing.sql'
               OR script_name LIKE '%00_03a_fix_scriptsrunerrors_table_casing.sql'
            """));
        Assert.Equal(6, await requested.ExecuteAsync("""
            DELETE FROM grate_GrateScriptsRun
            WHERE script_name LIKE '%01a_drop_version_casing_helper.sql'
               OR script_name LIKE '%01a_drop_scriptsrun_casing_helper.sql'
               OR script_name LIKE '%01a_drop_scriptsrunerrors_casing_helper.sql'
            """));
    }

    private static async Task Leave_bootstrap_interrupted_after_helper_creation(DatabaseScenario scenario)
    {
        await using var requested = new MySqlConnection(scenario.Configuration.ConnectionString);
        // A failed old bootstrap recorded CREATE, but left CALL/DROP unfinished.
        await requested.ExecuteAsync("""
            CREATE PROCEDURE create_grate_fix_version_table_casing()
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'case-insensitive repair must not call the old helper'
            """);
        Assert.Equal(1, await requested.ExecuteAsync("""
            UPDATE grate_GrateScriptsRun SET text_hash = 'previous-casing-definition'
            WHERE script_name = 'grate-internal/00_02a_fix_version_table_casing.sql'
            """));
        Assert.Equal(2, await requested.ExecuteAsync("""
            DELETE FROM grate_GrateScriptsRun
            WHERE script_name IN ('grate-internal/00_02b_fix_version_table_casing_calling_proc.sql',
                'grate-internal/00_02c_fix_version_table_casing_drop_proc.sql')
            """));
    }

    private async Task<DatabaseScenario> CreateScenario(int lowerCaseTableNames, bool differentCase = false)
    {
        var container = new MariaDbBuilder(testConfig.DockerImage ?? "mariadb:10.4")
            .WithCommand($"--lower_case_table_names={lowerCaseTableNames}")
            .WithPassword("Case215Password42")
            .Build();
        DirectoryInfo? directory = null;
        var cancellationToken = TestContext.Current.CancellationToken;

        try
        {
            await container.StartAsync(cancellationToken);
            directory = Directory.CreateTempSubdirectory("grate-215-");
            var scenario = new DatabaseScenario(container, directory, lowerCaseTableNames, differentCase);

            await using var admin = new MySqlConnection(scenario.ConnectionString("mysql"));
            Assert.Equal(lowerCaseTableNames, await admin.ExecuteScalarAsync<int>("SELECT @@lower_case_table_names"));
            await admin.ExecuteAsync($"CREATE DATABASE `{OriginalDatabase}`");
            await using var original = new MySqlConnection(scenario.ConnectionString(OriginalDatabase));
            await original.ExecuteAsync("CREATE TABLE existing_data (value INT NOT NULL); INSERT INTO existing_data VALUES (17)");

            var up = Directory.CreateDirectory(Path.Combine(directory.FullName, scenario.Configuration.Folders!["Up"]!.Path));
            await File.WriteAllTextAsync(Path.Combine(up.FullName, ScriptName),
                "CREATE TABLE casing_migration (value INT NOT NULL); INSERT INTO casing_migration VALUES (42);", cancellationToken);
            return scenario;
        }
        catch
        {
            try
            {
                directory?.Delete(recursive: true);
            }
            finally
            {
                await container.DisposeAsync();
            }
            throw;
        }
    }

    private static async Task<bool> DatabaseExists(GrateConfiguration config)
    {
        await using var database = new MariaDbDatabase(NullLogger<MariaDbDatabase>.Instance);
        await database.InitializeConnections(config);
        database.SetDefaultConnectionActive();
        return await database.DatabaseExists();
    }

    private sealed class DatabaseScenario : IAsyncDisposable
    {
        private readonly MariaDbContainer _container;
        private readonly DirectoryInfo _directory;

        public DatabaseScenario(MariaDbContainer container, DirectoryInfo directory, int lowerCaseTableNames, bool differentCase)
        {
            _container = container;
            _directory = directory;
            RequestedDatabase = differentCase ? "case215database" : OriginalDatabase;
            ReusesOriginalDatabase = lowerCaseTableNames == 1 || !differentCase;
            Configuration = new GrateConfiguration
            {
                ConnectionString = ConnectionString(RequestedDatabase),
                // An existing database must not require an administrative connection.
                AdminConnectionString = ReusesOriginalDatabase ? "Invalid stuff" : ConnectionString("mysql"),
                CreateDatabase = true,
                SqlFilesDirectory = directory,
                OutputPath = new DirectoryInfo(Path.Combine(directory.FullName, "output")),
                Folders = Folders.Default,
                NonInteractive = true,
                CommandTimeout = 10,
                AdminCommandTimeout = 10
            };
        }

        public string RequestedDatabase { get; }
        public bool ReusesOriginalDatabase { get; }
        public GrateConfiguration Configuration { get; }

        public string ConnectionString(string databaseName) => new MySqlConnectionStringBuilder(_container.GetConnectionString())
        {
            UserID = "root",
            Database = databaseName,
            Pooling = false
        }.ConnectionString;

        public async ValueTask DisposeAsync()
        {
            try
            {
                _directory.Delete(recursive: true);
            }
            finally
            {
                await _container.DisposeAsync();
            }
        }
    }
}

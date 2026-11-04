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
    [Theory]
    [InlineData(0, false)]
    [InlineData(0, true)]
    [InlineData(1, false)]
    [InlineData(1, true)]
    public async Task Database_names_follow_the_servers_case_sensitivity(int lowerCaseTableNames, bool differentCase)
    {
        var cancellationToken = TestContext.Current.CancellationToken;

        // Issue #215: a case-insensitive server must reuse an existing database even
        // when the connection string uses different casing. Mode 0 must keep names distinct.
        await using var container = new MariaDbBuilder(testConfig.DockerImage ?? "mariadb:10.4")
            .WithCommand($"--lower_case_table_names={lowerCaseTableNames}")
            .WithPassword("Case215Password42")
            .Build();
        await container.StartAsync(cancellationToken);

        string ConnectionString(string databaseName) => new MySqlConnectionStringBuilder(container.GetConnectionString())
        {
            UserID = "root",
            Database = databaseName,
            Pooling = false
        }.ConnectionString;

        await using var admin = new MySqlConnection(ConnectionString("mysql"));
        await admin.OpenAsync(cancellationToken);
        Assert.Equal(lowerCaseTableNames, await admin.ExecuteScalarAsync<int>("SELECT @@lower_case_table_names"));

        const string originalDatabase = "Case215Database";
        var requestedDatabase = differentCase ? "case215database" : originalDatabase;
        var reusesOriginalDatabase = lowerCaseTableNames == 1 || !differentCase;
        await admin.ExecuteAsync($"CREATE DATABASE `{originalDatabase}`");
        await using var original = new MySqlConnection(ConnectionString(originalDatabase));
        await original.OpenAsync(cancellationToken);
        await original.ExecuteAsync("CREATE TABLE existing_data (value INT NOT NULL); INSERT INTO existing_data VALUES (17)");

        var directory = Directory.CreateTempSubdirectory("grate-215-");
        try
        {
            var folders = Folders.Default;
            var up = Directory.CreateDirectory(Path.Combine(directory.FullName, folders["Up"]!.Path));
            const string scriptName = "215_database_casing.sql";
            await File.WriteAllTextAsync(Path.Combine(up.FullName, scriptName),
                "CREATE TABLE casing_migration (value INT NOT NULL); INSERT INTO casing_migration VALUES (42);", cancellationToken);

            var config = new GrateConfiguration
            {
                ConnectionString = ConnectionString(requestedDatabase),
                // An existing database must not require an administrative connection.
                AdminConnectionString = reusesOriginalDatabase ? "Invalid stuff" : ConnectionString("mysql"),
                CreateDatabase = true,
                SqlFilesDirectory = directory,
                OutputPath = new DirectoryInfo(Path.Combine(directory.FullName, "output")),
                Folders = folders,
                NonInteractive = true,
                CommandTimeout = 10,
                AdminCommandTimeout = 10
            };

            Assert.Equal(reusesOriginalDatabase, await DatabaseExists(config));
            Assert.False(await DatabaseExists(config with { ConnectionString = ConnectionString("Missing215Database") }));

            for (var run = 0; run < 3; run++)
            {
                await using (var configuredMigrator = migrator.WithConfiguration(config))
                {
                    await configuredMigrator.Migrate();
                }

                await using var requested = new MySqlConnection(ConnectionString(requestedDatabase));
                await requested.OpenAsync(cancellationToken);
                Assert.Equal(new[] { 42 }, await requested.QueryAsync<int>("SELECT value FROM casing_migration"));
                Assert.Equal(new[] { scriptName }, await requested.QueryAsync<string>("SELECT script_name FROM grate_ScriptsRun"));
                Assert.Equal(0, await requested.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM grate_ScriptsRunErrors"));

                if (run == 0)
                {
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
                else if (run == 1 && lowerCaseTableNames == 1)
                {
                    // A failed old bootstrap recorded CREATE, but left CALL/DROP unfinished.
                    await requested.ExecuteAsync("""
                        CREATE PROCEDURE create_grate_fix_version_table_casing()
                            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'case-insensitive repair must not call the old helper';
                        UPDATE grate_GrateScriptsRun SET text_hash = 'previous-casing-definition'
                        WHERE script_name = 'grate-internal/00_02a_fix_version_table_casing.sql';
                        """);
                    Assert.Equal(2, await requested.ExecuteAsync("""
                        DELETE FROM grate_GrateScriptsRun
                        WHERE script_name IN ('grate-internal/00_02b_fix_version_table_casing_calling_proc.sql',
                            'grate-internal/00_02c_fix_version_table_casing_drop_proc.sql')
                        """));
                }
                else
                {
                    Assert.Equal(0, await requested.ExecuteScalarAsync<int>("""
                        SELECT COUNT(*) FROM INFORMATION_SCHEMA.ROUTINES
                        WHERE ROUTINE_SCHEMA = DATABASE() AND ROUTINE_NAME IN (
                            'create_grate_fix_version_table_casing',
                            'create_grate_fix_scriptsrun_table_casing',
                            'create_grate_fix_scriptsrunerrors_table_casing')
                        """));
                }
            }

            Assert.Equal(new[] { 17 }, await original.QueryAsync<int>("SELECT value FROM existing_data"));
            Assert.Equal(reusesOriginalDatabase ? 1 : 0, await original.ExecuteScalarAsync<int>(
                "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'casing_migration'"));

            var databases = (await admin.QueryAsync<string>("SHOW DATABASES"))
                .Where(name => string.Equals(name, originalDatabase, StringComparison.OrdinalIgnoreCase))
                .ToArray();
            if (lowerCaseTableNames == 1)
            {
                Assert.Equal(new[] { "case215database" }, databases);
            }
            else
            {
                Assert.Contains(originalDatabase, databases);
                Assert.Equal(reusesOriginalDatabase ? 1 : 2, databases.Length);
                Assert.Contains(requestedDatabase, databases);
            }
        }
        finally
        {
            directory.Delete(recursive: true);
        }
    }

    private static async Task<bool> DatabaseExists(GrateConfiguration config)
    {
        await using var database = new MariaDbDatabase(NullLogger<MariaDbDatabase>.Instance);
        await database.InitializeConnections(config);
        database.SetDefaultConnectionActive();
        return await database.DatabaseExists();
    }
}

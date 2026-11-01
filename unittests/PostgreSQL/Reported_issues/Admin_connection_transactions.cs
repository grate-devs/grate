using Dapper;
using grate.Configuration;
using grate.Exceptions;
using grate.Migration;
using PostgreSQL.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace PostgreSQL.Reported_issues;

[Collection(nameof(PostgreSqlGrateTestContext))]
public sealed class Admin_connection_transactions(PostgreSqlGrateTestContext context) : IDisposable
{
    private readonly DirectoryInfo _root = Directory.CreateTempSubdirectory("grate-admin-transactions-");

    [Fact]
    public async Task Admin_connection_used_during_creation_enlists_in_the_migration_transaction()
    {
        var database = "admin_transaction_" + Guid.NewGuid().ToString("N");
        var folders = new FoldersConfiguration
        {
            CreateDatabase = new MigrationsFolder("create", connectionType: ConnectionType.Admin,
                transactionHandling: TransactionHandling.Autonomous)
        };
        folders.Add("admin", new MigrationsFolder("admin", connectionType: ConnectionType.Admin));
        folders.Add("fail", new MigrationsFolder("fail"));
        WriteScript("create", "001_create.sql", $"CREATE DATABASE {database};");
        WriteScript("admin", "002_admin.sql", $"CREATE TABLE public.{database}(id INTEGER);");
        WriteScript("fail", "003_fail.sql", "THIS IS INVALID SQL;");
        var config = context.Migrator.Configuration with
        {
            ConnectionString = context.ConnectionString(database),
            AdminConnectionString = context.AdminConnectionString,
            SqlFilesDirectory = _root,
            OutputPath = _root.CreateSubdirectory("output"),
            Folders = folders,
            Transaction = true,
            NonInteractive = true
        };

        using var admin = context.External.CreateAdminDbConnection();
        try
        {
            await using (var migrator = context.Migrator.WithConfiguration(config))
            {
                var error = await Assert.ThrowsAsync<MigrationFailed>(migrator.Migrate);
                Assert.Contains("42601", error.Message);
                Assert.Contains("003_fail.sql", error.Message);
            }

            // Setup uses the admin connection before the transaction starts. A later
            // transactional admin folder must reopen it so its changes roll back.
            Assert.False(await admin.QuerySingleAsync<bool>(
                "SELECT to_regclass(@table) IS NOT NULL", new { table = "public." + database }));
        }
        finally
        {
            await admin.ExecuteAsync($"DROP TABLE IF EXISTS public.{database};");
            await admin.ExecuteAsync($"DROP DATABASE IF EXISTS {database};");
        }
    }

    private void WriteScript(string folder, string file, string sql) =>
        File.WriteAllText(Path.Combine(_root.CreateSubdirectory(folder).FullName, file), sql);

    public void Dispose() => _root.Delete(recursive: true);
}

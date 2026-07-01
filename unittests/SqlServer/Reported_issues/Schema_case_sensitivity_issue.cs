using Dapper;
using grate.Configuration;
using grate.Migration;
using SqlServer.TestInfrastructure;
using TestCommon.Generic.Running_MigrationScripts;
using TestCommon.TestInfrastructure;
using static grate.Configuration.KnownFolderKeys;

namespace SqlServer.Reported_issues;

/// <summary>
/// Test for issue where grate fails when schema exists with different case in case-insensitive SQL Server.
/// </summary>
[Collection(nameof(SqlServerGrateTestContext))]
public class Schema_case_sensitivity_issue(SqlServerGrateTestContext context, ITestOutputHelper testOutput) 
    : MigrationsScriptsBase(context, testOutput)
{
    [Fact]
    public async Task Schema_with_different_case_should_not_cause_create_schema_failure()
    {
        var db = TestConfig.RandomDatabase();
        var parent = CreateRandomTempDirectory();
        
        // First migration with "RoundhousE" schema
        var config1 = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithSchema("RoundhousE")
            .WithFolders(FoldersConfiguration.Default())
            .WithSqlFilesDirectory(parent)
            .Build();

        await using (var migrator = Context.Migrator.WithConfiguration(config1))
        {
            CreateDummySql(parent, config1.Folders![Sprocs]);
            await migrator.Migrate();
        }

        // Verify schema was created
        string? schema;
        using (var conn = Context.CreateDbConnection(db))
        {
            schema = await conn.ExecuteScalarAsync<string>(
                "SELECT s.name FROM sys.schemas s WHERE UPPER(s.name) = UPPER('RoundhousE')");
        }
        Assert.NotNull(schema);

        // Second migration with "roundhouse" schema (different case)
        // This should NOT fail, as SQL Server is case-insensitive by default
        var config2 = GrateConfigurationBuilder.Create(Context.DefaultConfiguration)
            .WithConnectionString(Context.ConnectionString(db))
            .WithSchema("roundhouse")
            .WithFolders(FoldersConfiguration.Default())
            .WithSqlFilesDirectory(parent)
            .Build();

        await using (var migrator = Context.Migrator.WithConfiguration(config2))
        {
            CreateDummySql(parent, config2.Folders![Sprocs]);
            // This should not throw an exception
            await migrator.Migrate();
        }

        // Verify that only one schema exists (case-insensitive match)
        int schemaCount;
        using (var conn = Context.CreateDbConnection(db))
        {
            schemaCount = await conn.ExecuteScalarAsync<int>(
                "SELECT COUNT(*) FROM sys.schemas WHERE UPPER(name) = UPPER('roundhouse')");
        }
        Assert.Equal(1, schemaCount);
    }
}

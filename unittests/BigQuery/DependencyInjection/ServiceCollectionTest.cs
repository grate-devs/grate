using BigQuery.TestInfrastructure;
using grate.Configuration;
using grate.Infrastructure;
using TestCommon.Generic.Running_MigrationScripts;
using static grate.Configuration.KnownFolderKeys;

namespace BigQuery.DependencyInjection;

[Collection(nameof(BigQueryGrateTestContext))]
public class ServiceCollectionTest(BigQueryGrateTestContext context) : TestCommon.DependencyInjection.GrateServiceCollectionTest(context)
{
    protected override string VarcharType => "STRING";
    protected override string BigintType => "INT64";

    // BigQuery takes no PRIMARY KEY without NOT ENFORCED, and no length on STRING in the emulator
    protected override string CreateMigrationScript(DirectoryInfo sqlFolder, ISyntax syntax)
    {
        var knownFolders = FoldersConfiguration.Default();
        var tableName = "grate_test";
        MigrationsScriptsBase.WriteSql(sqlFolder, knownFolders[Up]!.Path, $"{tableName}_001_create_test_table.sql",
            $"CREATE TABLE {tableName} (id {BigintType} NOT NULL, name {VarcharType} NOT NULL)");
        MigrationsScriptsBase.WriteSql(sqlFolder, knownFolders[RunFirstAfterUp]!.Path, $"{tableName}_001_insert_test_data.sql",
            $"INSERT INTO {tableName} (id, name) VALUES (1, 'test')");
        return tableName;
    }
}

using TestCommon.Generic;
using SqlServerCaseSensitive.TestInfrastructure;

namespace SqlServerCaseSensitive;

[Collection(nameof(SqlServerCaseSensitiveGrateTestContext))]
public class MigrationTables(SqlServerCaseSensitiveGrateTestContext testContext, ITestOutputHelper testOutput)
    : GenericMigrationTables(testContext, testOutput)
{
    protected override string CountTableSql(string schemaName, string tableName)
    {
        return $@"
SELECT count(table_name) FROM INFORMATION_SCHEMA.TABLES
WHERE
TABLE_SCHEMA = '{schemaName}' AND
TABLE_NAME = '{tableName}' COLLATE Latin1_General_CS_AS
";
    }
}

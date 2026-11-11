using System.Data;
using System.Diagnostics.CodeAnalysis;
using Docker.DotNet.Models;
using grate.Infrastructure;
using grate.Migration;
using grate.Oracle.Infrastructure;
using grate.Oracle.Migration;
using Oracle.ManagedDataAccess.Client;
using TestCommon.TestInfrastructure;
using OracleDatabase = grate.Oracle.Migration.OracleDatabase;

namespace Oracle.TestInfrastructure;


[CollectionDefinition(nameof(OracleGrateTestContext))]
public class OracleTestCollection : ICollectionFixture<OracleGrateTestContext>;

public record OracleGrateTestContext(
    IGrateMigrator migrator,
    ITestDatabase testDatabase) : GrateTestContext(migrator, testDatabase)
{
    // public string DockerCommand(string serverName, string adminPassword) =>
    //     $"run -d --name {serverName} -p 1521 -e ORACLE_ENABLE_XDB=true -e ORACLE_PWD={adminPassword} -P container-registry.oracle.com/database/express:21.3.0-xe";

    public override IDbConnection GetDbConnection(string connectionString) => new OracleConnection(connectionString);

    public override Task DropDatabase(string databaseName)
    {
        // Closed test connections remain logged in while pooled; release this
        // user's idle sessions before the existing drop-user contract runs.
        OracleTestConnectionPools.ClearUserPool(External.ConnectionString(databaseName));
        return base.DropDatabase(databaseName);
    }

    public override ISyntax Syntax => new OracleSyntax();
    public override Type DbExceptionType => typeof(OracleException);

    public override Type DatabaseType => typeof(OracleDatabase);
    public override bool SupportsTransaction => false;

    public override SqlStatements Sql => new()
    {
        SelectVersion = "SELECT * FROM v$version WHERE banner LIKE 'Oracle%'",
        SleepTwoSeconds = "BEGIN sys.dbms_session.sleep(2); END;"
    };

    public override string ExpectedVersionPrefix => "Oracle "; // might have AI or not, depending on version
    public override bool SupportsCreateDatabase => true;
    public override bool SupportsSchemas => false;

}

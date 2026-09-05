using System.Data;
using System.Diagnostics.CodeAnalysis;
using grate.Infrastructure;
using grate.Migration;
using grate.SqlServer.Infrastructure;
using grate.SqlServer.Migration;
using Microsoft.Data.SqlClient;
using TestCommon.TestInfrastructure;

namespace SqlServer.TestInfrastructure;

[CollectionDefinition(nameof(SqlServerGrateTestContext))]
public class SqlServerTestCollection : ICollectionFixture<SqlServerGrateTestContext>;

public record SqlServerGrateTestContext : GrateTestContext
{
    public SqlServerGrateTestContext(
        IGrateMigrator migrator,
        string serverCollation, 
        ITestDatabase testDatabase) : base(migrator, testDatabase)
    {
        ServerCollation = serverCollation;
    }
    
    // ReSharper disable once UnusedMember.Global
    public SqlServerGrateTestContext(
        IGrateMigrator migrator, 
        ITestDatabase testDatabase): this(migrator, "Danish_Norwegian_CI_AS", testDatabase)
    {
    }
  
    public override IDbConnection GetDbConnection(string connectionString) => new SqlConnection(connectionString);

    public override ISyntax Syntax { get; } = new SqlServerSyntax();
    public override Type DbExceptionType => typeof(SqlException);

    public override Type DatabaseType => typeof(SqlServerDatabase);
    public override bool SupportsTransaction => true;

    public override SqlStatements Sql => new()
    {
        SelectVersion = "SELECT @@VERSION",
        // WAITFOR can return early under thread starvation. Recheck the deadline
        // so the timeout test cannot mistake an early return for a completed delay.
        SleepTwoSeconds =
            """
            SET NOCOUNT ON;
            DECLARE @deadline datetime2 = DATEADD(second, 2, SYSUTCDATETIME());
            WHILE SYSUTCDATETIME() < @deadline
            BEGIN
                WAITFOR DELAY '00:00:00.100';
            END;
            """,
        CreateUser = (db, user, password) => 
$"""
    USE {db};
    CREATE LOGIN {user} WITH PASSWORD = '{password}';
    CREATE USER {user} FOR LOGIN {user};
""",
        GrantAccess = (db, user) => 
$"""
    USE {db};
    ALTER ROLE db_owner ADD MEMBER {user};
""",
    };

    public override string ExpectedVersionPrefix => "Microsoft SQL Server 20";

    public override bool SupportsCreateDatabase => true;
    public override bool SupportsSchemas => true;

    public string ServerCollation { get; }
}

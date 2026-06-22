using System.Data;
using grate.Infrastructure;
using grate.Migration;
using grate.SqlServer.Infrastructure;
using grate.SqlServer.Migration;
using Microsoft.Data.SqlClient;
using TestCommon.TestInfrastructure;

namespace SqlServerCaseSensitive.TestInfrastructure;

[CollectionDefinition(nameof(SqlServerCaseSensitiveGrateTestContext))]
public class SqlServerCaseSensitiveTestCollection : ICollectionFixture<SqlServerCaseSensitiveGrateTestContext>;

public record SqlServerCaseSensitiveGrateTestContext
    : GrateTestContext
{
    public SqlServerCaseSensitiveGrateTestContext(
        IGrateMigrator migrator,
        string serverCollation,
        ITestDatabase testDatabase) : base(migrator, testDatabase)
    {
        ServerCollation = serverCollation;
    }

    // ReSharper disable once UnusedMember.Global
    public SqlServerCaseSensitiveGrateTestContext(
        IGrateMigrator migrator,
        ITestDatabase testDatabase) : this(migrator, "Danish_Norwegian_CS_AS", testDatabase) // Case Sensitive collation
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
        SleepTwoSeconds = "WAITFOR DELAY '00:00:02'",
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

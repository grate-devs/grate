using System.Data;
using grate.Configuration;
using grate.Infrastructure;
using grate.Migration;
using Dir = System.IO.Directory;

namespace TestCommon.TestInfrastructure;

public interface IGrateTestContext
{
    string AdminConnectionString { get; }
    string ConnectionString(string database);
    string UserConnectionString(string database);

    IGrateTestContext External => this;

    // These connections execute in the test host, even when the migrator runs
    // inside Docker and its configuration uses the internal network endpoint.
    IDbConnection CreateAdminDbConnection()
    {
        var host = External;
        return host.GetDbConnection(host.AdminConnectionString);
    }

    IDbConnection CreateDbConnection(string database)
    {
        var host = External;
        return host.GetDbConnection(host.ConnectionString(database));
    }

    ISyntax Syntax { get; }

    Type DbExceptionType { get; }
    Type DatabaseType { get; }
    bool SupportsTransaction { get; }

    SqlStatements Sql { get; }
    string ExpectedVersionPrefix { get; }

    // ReSharper disable once InconsistentNaming
    public GrateConfiguration DefaultConfiguration => new()
    {
        CreateDatabase = SupportsCreateDatabase,
        AdminConnectionString = AdminConnectionString,
        Version = "a.b.c.d",
        AlterDatabase = true,
        NonInteractive = true,
        Transaction = SupportsTransaction,
        OutputPath = Dir.CreateTempSubdirectory()
    };

    public Task DropDatabase(string databaseName);


    public IGrateMigrator Migrator { get; }

    //public bool SupportsSchemas => Migrator.SupportsSchemas();

    bool SupportsCreateDatabase { get; }
    bool SupportsSchemas { get; }
    IDbConnection GetDbConnection(string connectionString);
}

using System.Data;
using grate.Infrastructure;
using grate.Migration;
using Microsoft.Data.SqlClient;
using NSubstitute;
using TestCommon.TestInfrastructure;

namespace Basic_tests.Infrastructure;

public sealed class DatabaseConnections_
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void Test_process_connections_use_the_host_endpoint(bool containerMigration)
    {
        IGrateTestContext context = CreateContext(containerMigration);

        using var connection = context.CreateDbConnection("restored_database");
        using var admin = context.CreateAdminDbConnection();

        var actual = new SqlConnectionStringBuilder(connection.ConnectionString);
        Assert.Equal("localhost,49173", actual.DataSource);
        Assert.Equal("restored_database", actual.InitialCatalog);
        Assert.Equal("localhost,49173", new SqlConnectionStringBuilder(admin.ConnectionString).DataSource);
        Assert.Equal("master", new SqlConnectionStringBuilder(admin.ConnectionString).InitialCatalog);
    }

    [Fact]
    public void Container_migration_configuration_keeps_the_internal_endpoint()
    {
        IGrateTestContext context = CreateContext(containerMigration: true);

        Assert.Equal("sqlserver-test-container,1433",
            new SqlConnectionStringBuilder(context.ConnectionString("restored_database")).DataSource);
        Assert.Equal("sqlserver-test-container,1433",
            new SqlConnectionStringBuilder(context.DefaultConfiguration.AdminConnectionString).DataSource);

        using var connection = context.External.CreateDbConnection("restored_database");
        Assert.Equal("localhost,49173", new SqlConnectionStringBuilder(connection.ConnectionString).DataSource);
    }

    private static ConnectionContext CreateContext(bool containerMigration)
    {
        var host = Substitute.For<ITestDatabase>();
        host.AdminConnectionString.Returns("Server=localhost,49173;Database=master");
        host.ConnectionString("restored_database").Returns("Server=localhost,49173;Database=restored_database");
        host.External.Returns(host);
        if (!containerMigration) return new ConnectionContext(host);

        var docker = Substitute.For<ITestDatabase>();
        docker.AdminConnectionString.Returns("Server=sqlserver-test-container,1433;Database=master");
        docker.ConnectionString("restored_database").Returns("Server=sqlserver-test-container,1433;Database=restored_database");
        docker.External.Returns(host);
        return new ConnectionContext(docker);
    }

    private sealed record ConnectionContext(ITestDatabase Database)
        : GrateTestContext(Substitute.For<IGrateMigrator>(), Database)
    {
        public override IDbConnection GetDbConnection(string connectionString) => new SqlConnection(connectionString);
        public override bool SupportsCreateDatabase => true;
        public override bool SupportsSchemas => true;
        public override bool SupportsTransaction => true;
        public override ISyntax Syntax => throw new NotSupportedException();
        public override Type DbExceptionType => typeof(SqlException);
        public override Type DatabaseType => throw new NotSupportedException();
        public override SqlStatements Sql => throw new NotSupportedException();
        public override string ExpectedVersionPrefix => throw new NotSupportedException();
    }
}

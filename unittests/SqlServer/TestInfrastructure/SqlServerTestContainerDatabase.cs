using DotNet.Testcontainers.Containers;
using DotNet.Testcontainers.Networks;
using Microsoft.Extensions.Logging;
using TestCommon.TestInfrastructure;
using Testcontainers.MsSql;

namespace SqlServer.TestInfrastructure;

// ReSharper disable once ClassNeverInstantiated.Global
public record SqlServerTestContainerDatabase(
    GrateTestConfig GrateTestConfig,
    ILogger<SqlServerTestContainerDatabase> Logger,
    INetwork Network)
    : TestContainerDatabase(GrateTestConfig)
{
    // Run with linux/amd86 on ARM architectures too, the docker emulation is good enough
    public override string DockerImage => GrateTestConfig.DockerImage ?? "mcr.microsoft.com/mssql/server:2022-latest";
    protected override int InternalPort => MsSqlBuilder.MsSqlPort;
    protected override string NetworkAlias => "sqlserver-test-container";

    protected override IContainer InitializeTestContainer()
    {
        return new MsSqlBuilder(DockerImage)
            .WithEnvironment("DOCKER_DEFAULT_PLATFORM", "linux/amd64")
            .WithPassword(AdminPassword)
            .WithPortBinding(InternalPort, true)
            .WithEnvironment("MSSQL_COLLATION", "Danish_Norwegian_CI_AS")
            .WithLogger(Logger)
            .Build();
    }

    public override string AdminConnectionString =>
        $"Data Source={Hostname},{Port};Initial Catalog=master;User Id=sa;Password={AdminPassword};Encrypt=false;Pooling=false;Connect Timeout=5";

    public override string ConnectionString(string database) =>
        $"Data Source={Hostname},{Port};Initial Catalog={database};User Id=sa;Password={AdminPassword};Encrypt=false;Pooling=false;Connect Timeout=5"; // timeout = 5s will increase the test execution time, however, it will reduce the risk of transient connection issues in CI environments, which can be more common with SQL Server containers, especially in SQL Server 2025

    public override string UserConnectionString(string database) =>
        $"Data Source={Hostname},{Port};Initial Catalog={database};User Id=zorro;Password=batmanZZ4;Encrypt=false;Pooling=false;Connect Timeout=5"; // timeout = 5s will increase the test execution time, however, it will reduce the risk of transient connection issues in CI environments, which can be more common with SQL Server containers, especially in SQL Server 2025

}

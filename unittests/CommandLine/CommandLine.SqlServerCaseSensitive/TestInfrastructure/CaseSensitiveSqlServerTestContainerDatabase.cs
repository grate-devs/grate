using DotNet.Testcontainers.Builders;
using DotNet.Testcontainers.Containers;
using DotNet.Testcontainers.Networks;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;
using SqlServerCaseSensitive.TestInfrastructure;
using TestCommon.TestInfrastructure;
using Testcontainers.MsSql;

namespace CommandLine.SqlServerCaseSensitive.TestInfrastructure;

public record CaseSensitiveSqlServerTestContainerDatabase(
    GrateTestConfig GrateTestConfig,
    ILogger<SqlServerTestContainerDatabase> Logger,
    INetwork Network)
    : SqlServerTestContainerDatabase(GrateTestConfig, Logger, Network)
{
    protected override IContainer InitializeTestContainer() =>
        new MsSqlBuilder(DockerImage)
            .WithEnvironment("DOCKER_DEFAULT_PLATFORM", "linux/amd64")
            .WithPassword(AdminPassword)
            .WithPortBinding(InternalPort, true)
            .WithNetwork(Network)
            .WithNetworkAliases(NetworkAlias)
            .WithEnvironment("MSSQL_COLLATION", "Danish_Norwegian_CS_AS")
            // Wait for collation reindexing before opening test connections.
            .WithWaitStrategy(Wait.ForUnixContainer()
                .UntilMessageIsLogged("The default collation was successfully changed.",
                    wait => wait.WithTimeout(TimeSpan.FromMinutes(2))))
            .WithLogger(Logger)
            .Build();

    public override string AdminConnectionString => WithContainerHost(base.AdminConnectionString);

    public override string ConnectionString(string database) => WithContainerHost(base.ConnectionString(database));

    public override string UserConnectionString(string database) => WithContainerHost(base.UserConnectionString(database));

    private string WithContainerHost(string connectionString) =>
        new SqlConnectionStringBuilder(connectionString)
        {
            DataSource = $"{Hostname},{Port}"
        }.ConnectionString;
}

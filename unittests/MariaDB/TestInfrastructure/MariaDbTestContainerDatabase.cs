using DotNet.Testcontainers.Containers;
using DotNet.Testcontainers.Networks;
using Microsoft.Extensions.Logging;
using TestCommon.TestInfrastructure;
using Testcontainers.MariaDb;

namespace MariaDB.TestInfrastructure;

// ReSharper disable once ClassNeverInstantiated.Global
public record MariaDbTestContainerDatabase(
    GrateTestConfig GrateTestConfig,
    ILogger<MariaDbTestContainerDatabase> Logger,
    INetwork Network
    ) : TestContainerDatabase(GrateTestConfig)
{
    public override string DockerImage => GrateTestConfig.DockerImage ?? "mariadb:10.4";
    protected override int InternalPort => MariaDbBuilder.MariaDbPort;
    protected override string NetworkAlias => "mariadb-test-container";

    protected override IContainer InitializeTestContainer()
    {
        return new MariaDbBuilder(DockerImage)
            .WithCommand("--max_connections=10000")
            .WithPassword(AdminPassword)
            .WithPortBinding(InternalPort, true)
            .WithNetworkAliases(NetworkAlias)
            .WithNetwork(Network)
            .WithLogger(Logger)
            .Build();
    }

    public override string AdminConnectionString => $"Server={Hostname};Port={Port};Database=mysql;Uid=root;Pwd={AdminPassword}";
    public override string ConnectionString(string database) => $"Server={Hostname};Port={Port};Database={database};Uid=root;Pwd={AdminPassword}";
    public override string UserConnectionString(string database) => $"Server={Hostname};Port={Port};Database={database};Uid={database};Pwd=mooo1213";

}



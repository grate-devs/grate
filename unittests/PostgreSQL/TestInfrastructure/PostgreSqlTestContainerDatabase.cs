using DotNet.Testcontainers.Containers;
using DotNet.Testcontainers.Networks;
using Microsoft.Extensions.Logging;

namespace TestCommon.TestInfrastructure;

// ReSharper disable once ClassNeverInstantiated.Global
public record PostgreSqlTestContainerDatabase(
    GrateTestConfig GrateTestConfig,
    ILogger<PostgreSqlTestContainerDatabase> Logger,
    INetwork Network
    )
    : TestContainerDatabase(GrateTestConfig)
{
    public override string DockerImage => GrateTestConfig.DockerImage ?? "postgres:16";
    protected override int InternalPort => PostgreSqlBuilder.PostgreSqlPort;
    protected override string NetworkAlias => "postgresql-test-container";

    protected override IContainer InitializeTestContainer()
    {
        return new PostgreSqlBuilder(DockerImage)
            .WithPassword(AdminPassword)
            .WithPortBinding(InternalPort, true)
            .WithNetworkAliases(NetworkAlias)
            .WithNetwork(Network)
            .WithLogger(Logger)
            .Build();
    }
    
    public override string AdminConnectionString =>
        $"Host={Hostname};Port={Port};Database=postgres;Username=postgres;Password={AdminPassword};Include Error Detail=true;Pooling=false";


    public override string ConnectionString(string database) =>
        $"Host={Hostname};Port={Port};Database={database};Username=postgres;Password={AdminPassword};Include Error Detail=true;Pooling=false";

    public override string UserConnectionString(string database) =>
        $"Host={Hostname};Port={Port};Database={database};Username=postgres;Password={AdminPassword};Include Error Detail=true;Pooling=false";

    
}


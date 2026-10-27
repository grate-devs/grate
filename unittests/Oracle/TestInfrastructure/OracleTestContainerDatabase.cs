using System.Text;
using DotNet.Testcontainers.Containers;
using DotNet.Testcontainers.Networks;
using Microsoft.Extensions.Logging;
using Testcontainers.Oracle;

namespace TestCommon.TestInfrastructure;

// ReSharper disable once ClassNeverInstantiated.Global
public record OracleTestContainerDatabase(
    GrateTestConfig GrateTestConfig,
    ILogger<OracleTestContainerDatabase> Logger,
    INetwork Network) : TestContainerDatabase(GrateTestConfig)
{
    //public override string DockerImage => "gvenzl/oracle-xe:21.3.0-slim-faststart";
    public override string DockerImage => GrateTestConfig.DockerImage ?? "gvenzl/oracle-free:latest-faststart";
    protected override int InternalPort => OracleBuilder.OraclePort;
    protected override string NetworkAlias => "oracle-test-container";

    protected override IContainer InitializeTestContainer()
    {
        // Pooling is disabled: migration tests rapidly open and close dedicated connections.
        // The default listener capacity can reject this churn (ORA-12516), even when
        // the database's measured process count is below the image's default limit.
        // Reserve admission headroom only in this disposable database. PROCESSES is static,
        // so restart before the image emits its readiness message and tests can connect.
        const string configureTestDatabase = """
            WHENEVER OSERROR EXIT FAILURE
            WHENEVER SQLERROR EXIT FAILURE
            ALTER SYSTEM SET PROCESSES=1000 SCOPE=SPFILE;
            SHUTDOWN IMMEDIATE;
            STARTUP;
            ALTER PLUGGABLE DATABASE ALL OPEN;
            ALTER SYSTEM REGISTER;
            """;

        return new OracleBuilder(DockerImage)
            .WithEnvironment("DOCKER_DEFAULT_PLATFORM", "linux/amd64")
            .WithEnvironment("ORACLE_PDB", "FREEPDB1")
            .WithPassword(AdminPassword)
            .WithPortBinding(InternalPort, true)
            .WithLogger(Logger)
            .WithResourceMapping(Encoding.UTF8.GetBytes(configureTestDatabase),
                "/container-entrypoint-startdb.d/01-test-connection-capacity.sql")
            .Build();
    }
    
    public override string AdminConnectionString => $@"Data Source={TestContainer.Hostname}:{Port}/FREEPDB1;User ID=system;Password={AdminPassword};Pooling=False";
    public override string ConnectionString(string database) => $@"Data Source={TestContainer.Hostname}:{Port}/FREEPDB1;User ID={database.ToUpper()};Password={AdminPassword};Pooling=False";
    public override string UserConnectionString(string database) => $@"Data Source={TestContainer.Hostname}:{Port}/FREEPDB1;User ID={database.ToUpper()};Password={AdminPassword};Pooling=False";

}

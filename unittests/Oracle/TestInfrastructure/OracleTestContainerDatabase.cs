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
        // Database creation probes log in as missing users. Oracle delays every failed login
        // by one second; disable that delay only in these disposable test databases.
        // This undocumented parameter is static, so the test container must restart once.
        // Give the listener headroom for rapid short-lived connections between load updates.
        const string configureTestDatabase = """
            WHENEVER SQLERROR EXIT SQL.SQLCODE
            ALTER SYSTEM SET "_sys_logon_delay"=0 SCOPE=SPFILE;
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
            .WithNetwork(Network)
            .WithNetworkAliases(NetworkAlias)
            .WithLogger(Logger)
            .WithResourceMapping(Encoding.UTF8.GetBytes(configureTestDatabase),
                "/container-entrypoint-startdb.d/01-test-logon-delay.sql")
            .Build();
    }
    
    public override string AdminConnectionString => $@"Data Source={Hostname}:{Port}/FREEPDB1;User ID=system;Password={AdminPassword};Pooling=False";
    public override string ConnectionString(string database) => $@"Data Source={Hostname}:{Port}/FREEPDB1;User ID={database.ToUpper()};Password={AdminPassword};Pooling=False";
    public override string UserConnectionString(string database) => $@"Data Source={Hostname}:{Port}/FREEPDB1;User ID={database.ToUpper()};Password={AdminPassword};Pooling=False";

}

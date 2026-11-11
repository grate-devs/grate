using System.Text;
using DotNet.Testcontainers.Containers;
using DotNet.Testcontainers.Networks;
using Microsoft.Extensions.Logging;
using Oracle.TestInfrastructure;
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

    public override async ValueTask InitializeAsync()
    {
        await base.InitializeAsync();
        if (!string.Equals(Environment.GetEnvironmentVariable("GRATE_ORACLE_TEST_DISABLE_OOB"),
                "true", StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        // Match the image's 21c Docker-proxy cancellation workaround on the
        // disposable server. Wait until entrypoint has moved/symlinked sqlnet.ora.
        const string configureCancellation = """
            if [ -n "${TNS_ADMIN:-}" ]; then
                netdir="$TNS_ADMIN"
            else
                base="${ORACLE_BASE_HOME:-${ORACLE_HOME:-}}"
                test -n "$base"
                netdir="$base/network/admin"
            fi
            config="$netdir/sqlnet.ora"
            test -f "$config"
            if ! grep -Eiq '^[[:space:]]*DISABLE_OOB[[:space:]]*=' "$config"; then
                printf '\nDISABLE_OOB=ON\n' >> "$config"
            fi
            grep -Eiq '^[[:space:]]*DISABLE_OOB[[:space:]]*=[[:space:]]*ON[[:space:]]*$' "$config"
            printf 'Oracle test SQL*Net in-band cancellation configuration verified.\n'
            """;
        var result = await TestContainer.ExecAsync(["/bin/sh", "-ec", configureCancellation]);
        if (result.ExitCode != 0)
        {
            throw new InvalidOperationException($"Oracle test cancellation configuration failed with exit code {result.ExitCode}.");
        }
        Logger.LogWarning("Oracle test SQL*Net in-band cancellation configuration verified.");
    }

    protected override IContainer InitializeTestContainer()
    {
        // Database creation probes log in as missing users. Oracle delays every failed login
        // by one second; disable that delay only in these disposable test databases.
        // This undocumented parameter is static, so the test container must restart once.
        // Give the listener headroom for rapid short-lived connections between load updates.
        const string configureTestDatabase = """
            WHENEVER OSERROR EXIT FAILURE
            WHENEVER SQLERROR EXIT FAILURE
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

    public override string AdminConnectionString => OracleTestConnectionPools.Configure($@"Data Source={Hostname}:{Port}/FREEPDB1;User ID=system;Password={AdminPassword};Pooling=False");
    public override string ConnectionString(string database) => OracleTestConnectionPools.Configure($@"Data Source={Hostname}:{Port}/FREEPDB1;User ID={database.ToUpper()};Password={AdminPassword};Pooling=False");
    public override string UserConnectionString(string database) => OracleTestConnectionPools.Configure($@"Data Source={Hostname}:{Port}/FREEPDB1;User ID={database.ToUpper()};Password={AdminPassword};Pooling=False");

}

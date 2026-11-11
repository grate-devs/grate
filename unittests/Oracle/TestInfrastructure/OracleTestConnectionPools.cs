using System.Reflection;
using Oracle.ManagedDataAccess.Client;
using Xunit.v3;

namespace Oracle.TestInfrastructure;

internal static class OracleTestConnectionPools
{
    private static readonly AsyncLocal<bool> UnpooledScope = new();

    // These sources are also compiled into CommandLine/Docker assemblies, whose
    // separately launched candidates cannot share this test host's pool lifetime.
    private static bool ExperimentEnabled => typeof(OracleTestConnectionPools).Assembly.GetName().Name == "Oracle"
                                    && string.Equals(Environment.GetEnvironmentVariable("GRATE_ORACLE_SCOPED_POOLING"),
                                        "true", StringComparison.OrdinalIgnoreCase);

    internal static bool Enabled => ExperimentEnabled && !UnpooledScope.Value;

    internal static void UseUnpooledConnections(bool value) => UnpooledScope.Value = value;

    internal static string Configure(string connectionString)
    {
        if (!ExperimentEnabled)
        {
            return connectionString;
        }

        if (UnpooledScope.Value)
        {
            return new OracleConnectionStringBuilder(connectionString) { Pooling = false }.ConnectionString;
        }

        return new OracleConnectionStringBuilder(connectionString)
        {
            Pooling = true,
            MinPoolSize = 0,
            MaxPoolSize = 4
        }.ConnectionString;
    }

    internal static void ClearUserPool(string connectionString)
    {
        if (Enabled)
        {
            using var connection = new OracleConnection(connectionString);
            OracleConnection.ClearPool(connection);
        }
    }

    internal static void ClearAll()
    {
        if (ExperimentEnabled)
        {
            OracleConnection.ClearAllPools();
        }
    }
}

public sealed class UnpooledOracleTestAttribute : BeforeAfterTestAttribute
{
    public override void Before(MethodInfo methodUnderTest, IXunitTest test) => OracleTestConnectionPools.UseUnpooledConnections(true);

    public override void After(MethodInfo methodUnderTest, IXunitTest test) => OracleTestConnectionPools.UseUnpooledConnections(false);
}

public sealed class OracleTestPoolScopeAttribute : BeforeAfterTestAttribute
{
    public override void Before(MethodInfo methodUnderTest, IXunitTest test) => OracleTestConnectionPools.ClearAll();

    public override void After(MethodInfo methodUnderTest, IXunitTest test) => OracleTestConnectionPools.ClearAll();
}

using Oracle.ManagedDataAccess.Client;
using Oracle.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace Oracle;

[Collection(nameof(OracleGrateTestContext))]
public sealed class ConnectionPooling(OracleGrateTestContext context, GrateTestConfig configuration)
{
    [Fact]
    public void Fixture_connections_use_the_selected_pooling_policy()
    {
        var scoped = string.Equals(Environment.GetEnvironmentVariable("GRATE_ORACLE_SCOPED_POOLING"),
            "true", StringComparison.OrdinalIgnoreCase);
        var externalPooling = configuration.AdminConnectionString is { } external
                              && new OracleConnectionStringBuilder(external).Pooling;
        var expectedPooling = scoped || externalPooling;

        foreach (var value in new[]
                 {
                     context.AdminConnectionString,
                     context.ConnectionString("POOL_POLICY_PROBE"),
                     context.UserConnectionString("POOL_POLICY_PROBE")
                 })
        {
            var connection = new OracleConnectionStringBuilder(value);
            Assert.Equal(expectedPooling, connection.Pooling);
            if (scoped)
            {
                Assert.Equal(0, connection.MinPoolSize);
                Assert.Equal(4, connection.MaxPoolSize);
            }
        }
    }
}

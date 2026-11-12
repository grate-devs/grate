using System.Reflection;
using Microsoft.Data.SqlClient;

namespace SqlServer.TestInfrastructure;

internal static class SqlServerScopedPooling
{
    // Only the ordinary SQL Server assembly installs the serial-case hook.
    // Source-linked CLI/Docker fixtures never activate this state.
    private static volatile bool enabled;

    internal static bool ContainerFixtureSelected { get; private set; }

    internal static void ConfigureFixture(bool isContainer) => ContainerFixtureSelected = isContainer;

    internal static bool IsOptedIn(string? value) => bool.TryParse(value, out var parsed) && parsed;

    internal static IDisposable BeginCase(bool usePooling, bool clearPools = true)
    {
        var previous = enabled;
        if (clearPools)
        {
            SqlConnection.ClearAllPools();
        }
        enabled = usePooling;
        return new Scope(previous, clearPools);
    }

    internal static bool IsUnpooledCase(MethodInfo method) =>
        method.IsDefined(typeof(UnpooledSqlServerAttribute), inherit: true) ||
        method.DeclaringType?.IsDefined(typeof(UnpooledSqlServerAttribute), inherit: true) == true;

    internal static string TargetConnectionString(string connectionString)
    {
        if (!enabled)
        {
            return connectionString;
        }

        var builder = new SqlConnectionStringBuilder(connectionString);
        if (builder.IntegratedSecurity || !builder.UserID.Equals("sa", StringComparison.OrdinalIgnoreCase) ||
            string.IsNullOrEmpty(builder.InitialCatalog) ||
            new[] { "master", "model", "msdb", "tempdb" }.Contains(builder.InitialCatalog, StringComparer.OrdinalIgnoreCase))
        {
            return connectionString;
        }

        builder.Pooling = true;
        // Unpooled missing-database probes do not cache login failures. Preserve
        // that behavior while retaining the explicit AlwaysBlock regression.
        builder.PoolBlockingPeriod = PoolBlockingPeriod.NeverBlock;
        builder.MinPoolSize = 0;
        builder.MaxPoolSize = 4;
        return builder.ConnectionString;
    }

    private sealed class Scope(bool previous, bool clearPools) : IDisposable
    {
        private bool disposed;

        public void Dispose()
        {
            if (disposed)
            {
                return;
            }
            disposed = true;
            enabled = previous;
            // Leased connections are discarded when their owners return them;
            // clearing cannot replace the tests' normal connection disposal.
            if (clearPools)
            {
                SqlConnection.ClearAllPools();
            }
        }
    }
}

using System.Reflection;
using SqlServer.TestInfrastructure;
using Xunit.v3;

[assembly: SqlServer.SqlServerPoolingScope]

namespace SqlServer;

// Assembly parallelization is None in Startup.cs. State and pool clearing are
// intentionally process-wide and must never run concurrently with another case.
public sealed class SqlServerPoolingScopeAttribute : BeforeAfterTestAttribute
{
    private IDisposable? scope;

    public override void Before(MethodInfo methodUnderTest, IXunitTest test)
    {
        var optedIn = SqlServerScopedPooling.ContainerFixtureSelected &&
            SqlServerScopedPooling.IsOptedIn(Environment.GetEnvironmentVariable("GRATE_SQLSERVER_SCOPED_POOLING"));
        scope = SqlServerScopedPooling.BeginCase(
            optedIn && !SqlServerScopedPooling.IsUnpooledCase(methodUnderTest), clearPools: optedIn);
    }

    public override void After(MethodInfo methodUnderTest, IXunitTest test)
    {
        try
        {
            scope?.Dispose();
        }
        finally
        {
            scope = null;
        }
    }
}

using CommandLine.SqlServerCaseSensitive.TestInfrastructure;
using grate.Configuration;
using SqlServerCaseSensitive.TestInfrastructure;

[assembly: Xunit.v3.Parallelization(Mode = Xunit.Sdk.ParallelMode.None)]

namespace CommandLine.SqlServerCaseSensitive;

// ReSharper disable once UnusedType.Global
public class Startup : Common.Startup<CaseSensitiveSqlServerTestContainerDatabase, CaseSensitiveSqlServerExternalDatabase, SqlServerCaseSensitiveGrateTestContext>
{
    protected override DatabaseType DatabaseType => DatabaseType.SQLServer;
}

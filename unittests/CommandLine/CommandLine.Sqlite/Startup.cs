using grate.Configuration;
using Sqlite.TestInfrastructure;
using TestCommon.TestInfrastructure;

[assembly: Xunit.v3.Parallelization(Mode = Xunit.Sdk.ParallelMode.None)]

namespace CommandLine.Sqlite;

// ReSharper disable once UnusedType.Global
public class Startup : CommandLine.Common.Startup<SqliteTestDatabase, SqliteTestDatabase, SqliteGrateTestContext>
{
    protected override DatabaseType DatabaseType => DatabaseType.SQLite;
}

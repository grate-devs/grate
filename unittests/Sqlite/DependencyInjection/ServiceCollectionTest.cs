using grate.Infrastructure;
using grate.Sqlite.Migration;
using Sqlite.TestInfrastructure;
using TestCommon.TestInfrastructure;

namespace Sqlite.DependencyInjection;

public class ServiceCollectionTest(SqliteGrateTestContext context) : TestCommon.DependencyInjection.GrateServiceCollectionTest(context)
{
    protected override string VarcharType => "nvarchar";
    protected override string BigintType => "BIGINT";
}

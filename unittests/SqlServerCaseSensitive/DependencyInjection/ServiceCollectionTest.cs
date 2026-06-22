using SqlServerCaseSensitive.TestInfrastructure;

namespace SqlServerCaseSensitive.DependencyInjection;

[Collection(nameof(SqlServerCaseSensitiveGrateTestContext))]
public class ServiceCollectionTest(SqlServerCaseSensitiveGrateTestContext context)
    : TestCommon.DependencyInjection.GrateServiceCollectionTest(context)
{
    protected override string VarcharType => "nvarchar";
    protected override string BigintType => "BIGINT";
}

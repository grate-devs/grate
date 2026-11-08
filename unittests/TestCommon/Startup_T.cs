using System.Diagnostics.CodeAnalysis;
using TestCommon.TestInfrastructure;

namespace TestCommon;

public abstract class Startup<
    [DynamicallyAccessedMembers(DynamicallyAccessedMemberTypes.PublicConstructors)] TTestContainerDatabase,
    [DynamicallyAccessedMembers(DynamicallyAccessedMemberTypes.PublicConstructors)] TExternalDatabase,
    [DynamicallyAccessedMembers(DynamicallyAccessedMemberTypes.PublicConstructors)] TGrateTestContext> : Startup
    where TTestContainerDatabase : ITestDatabase
    where TExternalDatabase : ITestDatabase
    where TGrateTestContext : IGrateTestContext
{
    [DynamicallyAccessedMembers(DynamicallyAccessedMemberTypes.PublicConstructors)]
    protected override Type TestContainerDatabaseType => typeof(TTestContainerDatabase);

    [DynamicallyAccessedMembers(DynamicallyAccessedMemberTypes.PublicConstructors)]
    protected override Type ExternalTestDatabaseType => typeof(TExternalDatabase);

    [DynamicallyAccessedMembers(DynamicallyAccessedMemberTypes.PublicConstructors)]
    protected override Type TestContextType => typeof(TGrateTestContext);
}

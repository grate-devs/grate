using grate.Migration;

namespace TestCommon.TestInfrastructure;

internal static class GrateMigratorExtensions
{
    public static IDbMigrator GetDbMigrator(this IGrateMigrator migrator)
    {
        return (migrator as GrateMigrator)!.DbMigrator;
    }
}

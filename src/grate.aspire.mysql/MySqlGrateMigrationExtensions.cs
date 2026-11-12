using Aspire.Hosting.ApplicationModel;

namespace Grate.Aspire.Hosting;

/// <summary>Models grate migrations for native Aspire MySQL database resources.</summary>
public static class MySqlGrateMigrationExtensions
{
    /// <summary>Adds a grate migration for a MySQL database provisioned by Aspire.</summary>
    /// <remarks>
    /// Aspire creates the database after the server becomes ready. Grate migrates it using
    /// its MariaDB/MySQL provider, with database creation disabled by default.
    /// Connection information remains deferred. Consumers opt into successful completion
    /// with WaitForCompletion; this method does not alter consumer resources.
    /// </remarks>
    public static IResourceBuilder<GrateMigrationResource> AddGrateMigration(
        this IResourceBuilder<MySqlDatabaseResource> database,
        string? name = null,
        bool waitForDatabase = true) =>
        GrateMigrationExtensions.AddGrateMigration(database, GrateDatabaseProvider.MySql, name, waitForDatabase);
}

using Aspire.Hosting.ApplicationModel;

namespace Grate.Aspire.Hosting;

/// <summary>Models grate migrations for native Aspire Oracle database resources.</summary>
public static class OracleGrateMigrationExtensions
{
    /// <summary>Adds a grate migration targeting an existing Oracle service or pluggable database.</summary>
    /// <remarks>
    /// Aspire's AddDatabase selects a service name; it does not provision a PDB or database user.
    /// Provision the service and credentials before migration. The native Oracle resource uses
    /// SYSTEM credentials, and grate database creation remains disabled by default.
    /// Consumers opt into successful completion with WaitForCompletion.
    /// </remarks>
    public static IResourceBuilder<GrateMigrationResource> AddGrateMigration(
        this IResourceBuilder<OracleDatabaseResource> database,
        string? name = null,
        bool waitForDatabase = true) =>
        GrateMigrationExtensions.AddGrateMigration(database, GrateDatabaseProvider.Oracle, name, waitForDatabase);
}

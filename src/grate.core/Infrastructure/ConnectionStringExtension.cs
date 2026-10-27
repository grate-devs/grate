using System.Data.Common;
using grate.Configuration;
using grate.Migration;

namespace grate.Infrastructure;
internal static class ConnectionStringExtension
{
    public static string? GetAdminConnectionString(this IDatabase database, GrateConfiguration grateConfiguration)
    {
        if (grateConfiguration.AdminConnectionString is not null)
        {
            return grateConfiguration.AdminConnectionString;
        }
        if (grateConfiguration.ConnectionString is not null)
        {
            return WithAdminDb(grateConfiguration.ConnectionString, database.MasterDatabaseName);
        }
        return default;

    }
    private static string WithAdminDb(string connectionString, string masterDatabaseName)
    {
        var builder = new ParsedConnectionStringBuilder { ConnectionString = connectionString };
        var hasCatalog = false;
        // Update both aliases when present so provider alias precedence cannot retain the target database.
        foreach (var key in new[] { "Initial Catalog", "Database" })
        {
            if (builder.ContainsKey(key) || builder.EmptyKeys.Contains(key))
            {
                builder[key] = masterDatabaseName;
                hasCatalog = true;
            }
        }
        return hasCatalog ? builder.ConnectionString : connectionString;
    }

    private sealed class ParsedConnectionStringBuilder : DbConnectionStringBuilder
    {
        public HashSet<string> EmptyKeys { get; } = new(StringComparer.OrdinalIgnoreCase);

        public override bool Remove(string keyword)
        {
            // The parser removes unquoted empty values. Retain their keys so an explicit empty catalog is replaced too.
            EmptyKeys.Add(keyword);
            return base.Remove(keyword);
        }
    }
}

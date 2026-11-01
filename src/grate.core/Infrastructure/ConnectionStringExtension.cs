using System.Data.Common;
using System.Diagnostics.CodeAnalysis;
using System.Text;
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
        if (!builder.Entries.Any(entry => IsCatalog(entry.Key)))
        {
            return connectionString;
        }

        var result = new StringBuilder();
        foreach (var (key, value) in builder.Entries)
        {
            var rewrittenValue = IsCatalog(key) ? masterDatabaseName : value;
            DbConnectionStringBuilder.AppendKeyValuePair(result, key, rewrittenValue);
            // AppendKeyValuePair emits bare key= for both null and empty. Providers can distinguish a quoted empty value.
            if (rewrittenValue is { Length: 0 })
            {
                result.Append("\"\"");
            }
        }
        return result.ToString();
    }

    private static bool IsCatalog(string key) =>
        key.Equals("Initial Catalog", StringComparison.OrdinalIgnoreCase) ||
        key.Equals("Database", StringComparison.OrdinalIgnoreCase);

    private sealed class ParsedConnectionStringBuilder : DbConnectionStringBuilder
    {
        // Keep duplicate keys in order so provider alias precedence is preserved.
        // null is an unquoted empty assignment; "" is a quoted empty value.
        public List<KeyValuePair<string, string?>> Entries { get; } = new();

        [AllowNull]
        public override object this[string keyword]
        {
            get => base[keyword];
            set
            {
                Entries.Add(new(keyword, value?.ToString()));
                base[keyword] = value;
            }
        }

        public override bool Remove(string keyword)
        {
            // The parser removes unquoted empty values; retain them as explicit empty overrides.
            Entries.Add(new(keyword, null));
            return base.Remove(keyword);
        }
    }
}

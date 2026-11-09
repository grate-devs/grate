using System.CommandLine;
#if ALL_DATABASES || MARIADB_ONLY
using grate.mariadb.DependencyInjection;
#endif
#if ALL_DATABASES || ORACLE_ONLY
using grate.oracle.DependencyInjection;
#endif
#if ALL_DATABASES || POSTGRESQL_ONLY
using grate.postgresql.DependencyInjection;
#endif
#if ALL_DATABASES || SQLITE_ONLY
using grate.sqlite.DependencyInjection;
#endif
#if ALL_DATABASES || SQLSERVER_ONLY
using grate.sqlserver.DependencyInjection;
#endif
using Microsoft.Extensions.DependencyInjection;

namespace grate.Configuration;

internal static class DatabaseProviders
{
    private static readonly DatabaseType[] Supported =
    [
#if ALL_DATABASES || SQLSERVER_ONLY
        DatabaseType.SQLServer,
#endif
#if ALL_DATABASES || ORACLE_ONLY
        DatabaseType.Oracle,
#endif
#if ALL_DATABASES || POSTGRESQL_ONLY
        DatabaseType.PostgreSQL,
#endif
#if ALL_DATABASES || MARIADB_ONLY
        DatabaseType.MariaDB,
#endif
#if ALL_DATABASES || SQLITE_ONLY
        DatabaseType.SQLite,
#endif
    ];

    internal static Option<DatabaseType> CreateDatabaseTypeOption()
    {
        var option = new Option<DatabaseType>("--databasetype", "--dt", "--dbt")
        {
            Description = "TELLS GRATE WHAT TYPE OF DATABASE IT IS RUNNING ON.",
            DefaultValueFactory = _ => Supported[0]
        };

        if (Supported.Length == 1)
        {
            var databaseType = Supported[0];
            var databaseName = databaseType.ToString();
            option.Description = $"This build supports {databaseName} only.";
            option.HelpName = databaseName;
            option.CompletionSources.Clear();
            option.CompletionSources.Add(databaseName);
            option.CustomParser = result =>
            {
                if (result.Tokens.Count != 1 ||
                    !Enum.TryParse<DatabaseType>(result.Tokens[0].Value, ignoreCase: true, out var parsed) ||
                    parsed != databaseType)
                {
                    result.AddError($"This build supports {databaseName} only. Use the all-in-one grate distribution for other databases.");
                }
                return databaseType;
            };
        }

        return option;
    }

    internal static IServiceCollection AddGrateDatabase(
        this IServiceCollection services, CommandLineGrateConfiguration config) =>
        config.DatabaseType switch
        {
#if ALL_DATABASES || MARIADB_ONLY
            DatabaseType.MariaDB => services.AddGrateWithMariaDb(config),
#endif
#if ALL_DATABASES || ORACLE_ONLY
            DatabaseType.Oracle => services.AddGrateWithOracle(config),
#endif
#if ALL_DATABASES || POSTGRESQL_ONLY
            DatabaseType.PostgreSQL => services.AddGrateWithPostgreSQL(config),
#endif
#if ALL_DATABASES || SQLSERVER_ONLY
            DatabaseType.SQLServer => services.AddGrateWithSqlServer(config),
#endif
#if ALL_DATABASES || SQLITE_ONLY
            DatabaseType.SQLite => services.AddGrateWithSqlite(config),
#endif
            _ => throw new ArgumentOutOfRangeException(nameof(config),
                config.DatabaseType,
                "Unknown target database type: " + config.DatabaseType)
        };
}

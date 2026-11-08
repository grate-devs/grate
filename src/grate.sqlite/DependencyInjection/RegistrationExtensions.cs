using grate.Configuration;
using grate.DependencyInjection;
using grate.Migration;
using grate.Sqlite.Migration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace grate.sqlite.DependencyInjection;

public static class RegistrationExtensions
{
    // ReSharper disable once InconsistentNaming
    public static IServiceCollection UseSqlite(this IServiceCollection services)
    {
        services.TryAddTransient<IDatabase, SqliteDatabase>();
        return services;
    }

    // ReSharper disable once InconsistentNaming
    public static IServiceCollection AddGrateWithSqlite(this IServiceCollection services, GrateConfiguration? config = null) =>
        services
            .AddGrate(config ?? GrateConfiguration.Default)
            .UseSqlite();
}

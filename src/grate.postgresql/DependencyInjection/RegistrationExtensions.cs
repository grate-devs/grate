using grate.Configuration;
using grate.DependencyInjection;
using grate.Migration;
using grate.PostgreSql.Migration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace grate.postgresql.DependencyInjection;

public static class RegistrationExtensions
{
    // ReSharper disable once InconsistentNaming
    public static IServiceCollection UsePostgreSQL(this IServiceCollection services)
    {
        services.TryAddTransient<IDatabase, PostgreSqlDatabase>();
        return services;
    }

    // ReSharper disable once InconsistentNaming
    public static IServiceCollection AddGrateWithPostgreSQL(this IServiceCollection services, GrateConfiguration? config = null) =>
        services
            .AddGrate(config ?? GrateConfiguration.Default)
            .UsePostgreSQL();
}

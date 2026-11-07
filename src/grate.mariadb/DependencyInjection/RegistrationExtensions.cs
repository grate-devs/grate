using grate.Configuration;
using grate.DependencyInjection;
using grate.MariaDb.Migration;
using grate.Migration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace grate.mariadb.DependencyInjection;

public static class RegistrationExtensions
{
    public static IServiceCollection UseMariaDb(this IServiceCollection services)
    {
        services.TryAddTransient<IDatabase, MariaDbDatabase>();
        return services;
    }

    public static IServiceCollection AddGrateWithMariaDb(this IServiceCollection services, GrateConfiguration? config = null) =>
        services
            .AddGrate(config ?? GrateConfiguration.Default)
            .UseMariaDb();
}

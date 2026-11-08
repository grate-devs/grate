using grate.Configuration;
using grate.DependencyInjection;
using grate.Migration;
using grate.Oracle.Migration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace grate.oracle.DependencyInjection;

public static class RegistrationExtensions
{
    public static IServiceCollection UseOracle(this IServiceCollection services)
    {
        services.TryAddTransient<IDatabase, OracleDatabase>();
        return services;
    }

    public static IServiceCollection AddGrateWithOracle(this IServiceCollection services, GrateConfiguration? config = null) =>
        services
            .AddGrate(config ?? GrateConfiguration.Default)
            .UseOracle();
}

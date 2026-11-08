using grate.Configuration;
using grate.DependencyInjection;
using grate.Migration;
using grate.SqlServer.Migration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace grate.sqlserver.DependencyInjection;

public static class RegistrationExtensions
{
    // ReSharper disable once InconsistentNaming
    public static IServiceCollection UseSqlServer(this IServiceCollection services)
    {
        services.TryAddTransient<IDatabase, SqlServerDatabase>();
        return services;
    }

    // ReSharper disable once InconsistentNaming
    public static IServiceCollection AddGrateWithSqlServer(this IServiceCollection services, GrateConfiguration? config = null) =>
        services
            .AddGrate(config ?? GrateConfiguration.Default)
            .UseSqlServer();
}

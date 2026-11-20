using grate.BigQuery.Migration;
using grate.Configuration;
using grate.DependencyInjection;
using grate.Migration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace grate.bigquery.DependencyInjection;

public static class RegistrationExtensions
{
    public static IServiceCollection UseBigQuery(this IServiceCollection services)
    {
        services.TryAddTransient<IDatabase, BigQueryDatabase>();
        return services;
    }

    public static IServiceCollection AddGrateWithBigQuery(this IServiceCollection services, GrateConfiguration? config = null) =>
        services
            .AddGrate(config ?? GrateConfiguration.Default)
            .UseBigQuery();
}

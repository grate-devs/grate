using grate.Configuration;

namespace grate.Migration;

public interface IGrateMigrator : IAsyncDisposable
{
    /// <summary>
    /// Trigger grate migration with the given configuration
    /// </summary>
    /// <returns></returns>
    Task Migrate();

    GrateConfiguration Configuration { get; }

    IGrateMigrator WithConfiguration(GrateConfiguration configuration);
    IGrateMigrator WithConfiguration(Action<GrateConfigurationBuilder> builder);
    IGrateMigrator WithDatabase(IDatabase database);
}

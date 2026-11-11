using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;

namespace Grate.Aspire.Hosting;

/// <summary>Models grate migrations as Aspire container resources.</summary>
public static class GrateMigrationExtensions
{
    // Own argument construction instead of appending duplicate options to the image's
    // fixed /db entrypoint. User values remain arguments/environment, never shell source.
    private const string Launcher = """
        set -eu
        scripts_directory=$1
        shift
        exec /app/grate \
          --sqlfilesdirectory="$scripts_directory" \
          --connstring="$APP_CONNSTRING" \
          --databasetype="$DATABASE_TYPE" \
          --createdatabase="$CREATE_DATABASE" \
          --environment="$ENVIRONMENT" \
          --version="${VERSION:-1.0.0}" \
          --transaction="${TRANSACTION:-false}" \
          --outputPath="${GRATE_OUTPUT_PATH:-/output}" \
          --silent "$@"
        """;

    /// <summary>Adds a grate 2.3.0 migration for a PostgreSQL database.</summary>
    /// <remarks>
    /// Connection information stays deferred until Aspire configures the container.
    /// Use Aspire's WithEnvironment and WithImage methods to override the defaults.
    /// Consumers opt into waiting with WaitForCompletion; this method does not alter them.
    /// An override image must provide /bin/sh and /app/grate with grate's CLI contract.
    /// </remarks>
    public static IResourceBuilder<GrateMigrationResource> AddGrateMigration(
        this IResourceBuilder<PostgresDatabaseResource> database,
        string? name = null,
        bool waitForDatabase = true)
    {
        ArgumentNullException.ThrowIfNull(database);

        var resource = new GrateMigrationResource(name ?? $"{database.Resource.Name}-grate");
        var migration = database.ApplicationBuilder.AddResource(resource)
            .WithImage("gratedevs/grate", "2.3.0")
            .WithEntrypoint("/bin/sh")
            .WithEnvironment("APP_CONNSTRING", database.Resource.ConnectionStringExpression)
            .WithEnvironment("DATABASE_TYPE", "postgresql")
            .WithEnvironment("CREATE_DATABASE", "false")
            .WithEnvironment("ENVIRONMENT", "LOCAL")
            .WithArgs(context =>
            {
                var mount = resource.ScriptsMount ?? throw new InvalidOperationException(
                    "Configure the grate SQL directory with WithScriptsFolder before starting the migration.");
                context.Args.Add("-c");
                context.Args.Add(Launcher);
                // sh uses the first word following the script as $0, then forwards "$@".
                context.Args.Add("grate");
                context.Args.Add(mount.Target);
            });

        if (waitForDatabase)
        {
            migration.WaitFor(database);
        }

        return migration;
    }

    /// <summary>Mounts SQL scripts from an existing directory relative to the AppHost.</summary>
    /// <remarks>Calling this again replaces only the previous scripts mount.</remarks>
    public static IResourceBuilder<GrateMigrationResource> WithScriptsFolder(
        this IResourceBuilder<GrateMigrationResource> migration,
        string path,
        string containerPath = "/db",
        bool isReadOnly = true)
    {
        ArgumentNullException.ThrowIfNull(migration);
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        ArgumentException.ThrowIfNullOrWhiteSpace(containerPath);

        if (!containerPath.StartsWith('/') || containerPath == "/")
        {
            throw new ArgumentException("The scripts target must be an absolute container directory other than root.", nameof(containerPath));
        }

        var source = Path.GetFullPath(path, migration.ApplicationBuilder.AppHostDirectory);
        if (!Directory.Exists(source))
        {
            throw new DirectoryNotFoundException($"The grate scripts directory does not exist: {source}");
        }

        var resource = migration.Resource;
        if (resource.ScriptsMount is not null)
        {
            resource.Annotations.Remove(resource.ScriptsMount);
        }

        var mount = new ContainerMountAnnotation(source, containerPath, ContainerMountType.BindMount, isReadOnly);
        resource.Annotations.Add(mount);
        resource.ScriptsMount = mount;
        return migration;
    }
}

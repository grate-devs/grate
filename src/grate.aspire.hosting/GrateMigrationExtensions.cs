using System.Data.Common;
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

        var migration = AddMigration(database, name, "postgresql", database.Resource.ConnectionStringExpression);
        if (waitForDatabase)
        {
            migration.WaitFor(database);
        }

        return migration;
    }

    /// <summary>Adds a grate migration for a SQL Server database provisioned by Aspire.</summary>
    /// <remarks>Aspire creates the database after the server becomes ready; grate only migrates it.</remarks>
    public static IResourceBuilder<GrateMigrationResource> AddGrateMigration(
        this IResourceBuilder<SqlServerDatabaseResource> database,
        string? name = null,
        bool waitForDatabase = true)
    {
        ArgumentNullException.ThrowIfNull(database);

        var migration = AddMigration(database, name, "sqlserver", database.Resource.ConnectionStringExpression);
        if (waitForDatabase)
        {
            migration.WaitFor(database);
        }

        return migration;
    }

    /// <summary>Adds a migration for a file-backed SQLite resource in a dedicated absolute directory.</summary>
    /// <remarks>
    /// The whole database directory is mounted read-write so SQLite journal and WAL files share
    /// the same storage. The caller's resource connection string remains a host-side path.
    /// There is no database server to wait for. Consumers must still wait for migration completion.
    /// </remarks>
    public static IResourceBuilder<GrateMigrationResource> AddGrateMigration(
        this IResourceBuilder<SqliteResource> database,
        string? name = null,
        string containerDataPath = "/grate-data")
    {
        ArgumentNullException.ThrowIfNull(database);
        var target = NormalizeContainerPath(containerDataPath, nameof(containerDataPath));
        var filePath = GetSqliteFilePath(database.Resource);
        var directory = Path.GetDirectoryName(filePath)
            ?? throw new ArgumentException("SQLite requires a database file in a dedicated absolute directory.", nameof(database));

        // Binding the default shared temp directory would expose unrelated temporary files.
        if (Path.TrimEndingDirectorySeparator(directory) == Path.TrimEndingDirectorySeparator(Path.GetTempPath()) ||
            directory == Path.GetPathRoot(directory))
        {
            throw new ArgumentException("Configure SQLite with a dedicated database directory instead of a shared temporary directory or filesystem root.", nameof(database));
        }

        Directory.CreateDirectory(directory);
        var connection = new DbConnectionStringBuilder
        {
            ["Data Source"] = $"{target}/{Path.GetFileName(filePath)}",
            ["Cache"] = "Shared",
            ["Mode"] = "ReadWriteCreate"
        };
        var migration = AddMigration(database, name, "sqlite", ReferenceExpression.Create($"{connection.ConnectionString}"));
        var mount = new ContainerMountAnnotation(directory, target, ContainerMountType.BindMount, isReadOnly: false);
        migration.Resource.Annotations.Add(mount);
        migration.Resource.DataMount = mount;
        // The database and its journal/WAL files must remain writable by the host API.
        // A root container would otherwise create root-owned files in a non-root host directory.
        if (UnixContainerIdentity.Current is { } user)
        {
            migration.WithContainerRuntimeArgs("--user", user);
        }
        migration.WithEnvironment("DOTNET_BUNDLE_EXTRACT_BASE_DIR", "/tmp/grate-bundle")
            .WithEnvironment("GRATE_OUTPUT_PATH", "/tmp/grate-output");
        return migration;
    }

    private static IResourceBuilder<GrateMigrationResource> AddMigration<TResource>(
        IResourceBuilder<TResource> database,
        string? name,
        string databaseType,
        ReferenceExpression connectionString) where TResource : IResource
    {
        var resource = new GrateMigrationResource(name ?? $"{database.Resource.Name}-grate");
        return database.ApplicationBuilder.AddResource(resource)
            .WithImage("gratedevs/grate", "2.3.0")
            .WithEntrypoint("/bin/sh")
            .WithEnvironment("APP_CONNSTRING", connectionString)
            .WithEnvironment("DATABASE_TYPE", databaseType)
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
        var target = NormalizeContainerPath(containerPath, nameof(containerPath));
        if (migration.Resource.DataMount is { } dataMount && ContainerPathsOverlap(target, dataMount.Target))
        {
            throw new ArgumentException("The scripts target must not overlap the SQLite data directory.", nameof(containerPath));
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

        var mount = new ContainerMountAnnotation(source, target, ContainerMountType.BindMount, isReadOnly);
        resource.Annotations.Add(mount);
        resource.ScriptsMount = mount;
        return migration;
    }

    private static string GetSqliteFilePath(SqliteResource database)
    {
        // The toolkit keeps DatabasePath/DatabaseFileName internal, but exposes DataSource
        // through this public typed-property contract. Do not parse rendered connection strings.
        var dataSource = ((IResourceWithConnectionString)database).GetConnectionProperties()
            .Single(property => property.Key == "DataSource").Value;
        var filePath = dataSource.ValueExpression;
        // The toolkit interpolates this full path into its host connection string without
        // quoting it. Reject delimiters and trimming changes rather than mapping a different
        // filename into the container while the host opens another file (or cannot parse it).
        if (filePath.Contains(';') || filePath.Contains('\0') || filePath != filePath.Trim())
        {
            throw new NotSupportedException("The SQLite path must not contain connection-string delimiters or surrounding whitespace because the host resource cannot preserve that path.");
        }

        var fileName = Path.GetFileName(filePath);
        if (dataSource.ValueProviders.Count != 0 || !Path.IsPathFullyQualified(filePath) ||
            string.IsNullOrWhiteSpace(fileName) || fileName is "." or ".." ||
            fileName.Contains(':') || fileName.Contains('?'))
        {
            throw new NotSupportedException("SQLite migrations require an absolute filesystem database path; in-memory databases and URI connection sources are not supported.");
        }

        return Path.GetFullPath(filePath);
    }

    private static string NormalizeContainerPath(string path, string parameterName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path, parameterName);
        var segments = path.Split('/', StringSplitOptions.RemoveEmptyEntries).Where(segment => segment != ".").ToArray();
        if (!path.StartsWith('/') || segments.Length == 0 || segments.Contains("..") || path.Contains('\0'))
        {
            throw new ArgumentException("The target must be an absolute container directory other than root, without parent traversal.", parameterName);
        }

        return "/" + string.Join('/', segments);
    }

    private static bool ContainerPathsOverlap(string first, string second) =>
        first == second || first.StartsWith(second + "/", StringComparison.Ordinal) ||
        second.StartsWith(first + "/", StringComparison.Ordinal);
}

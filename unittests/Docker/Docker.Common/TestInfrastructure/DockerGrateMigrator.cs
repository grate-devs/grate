using System.Text.Json;
using System.Text.Json.Serialization;
using DotNet.Testcontainers.Builders;
using DotNet.Testcontainers.Networks;
using grate.Commands;
using grate.Configuration;
using grate.Migration;
using Microsoft.Extensions.Logging;
using Dir = System.IO.Directory;

namespace Docker.Common.TestInfrastructure;

public record DockerGrateMigrator(
    DatabaseType DatabaseType,
    ILogger<DockerGrateMigrator> Logger,
    INetwork Network,
    string? ApplicationDockerImage = null
    )
    : IGrateMigrator
{
    public DatabaseType DatabaseType { get; set; } = DatabaseType;

    internal string DockerImage => ApplicationDockerImage ?? "gratedevs/grate";

    public async Task Migrate()
    {
        await LocalDockerImage.Ensure(DockerImage, Logger, Xunit.TestContext.Current.CancellationToken);

        // Sqlite doesn't like to be extracted to a tmpfs mount, so we need to use a bind mount to a temporary folder
        // if not, we get an error like this:
        //  /home/app/.net/grate/fdcA3gxdjBiIcVt0mGoBJ5IgxSbD0kE=/libe_sqlite3.so: failed to map segment from shared object
        // (similarly) /tmp/dotnet-bundle-extract/grate/fdcA3gxdjBiIcVt0mGoBJ5IgxSbD0kE=/libe_sqlite3.so: failed to map segment from shared object
        var tmpFolder = Dir.CreateTempSubdirectory().ToString();

        // Need to map the SQL files directory to the container
        var sqlFilesDirectory = Configuration.SqlFilesDirectory.ToString();

        Dictionary<string, string> bindMounts = new Dictionary<string, string>
        {
            { tmpFolder, "/home/app" },
            { sqlFilesDirectory, sqlFilesDirectory }
        };

        // For Sqlite, the database file needs to be mapped as bind mounts, to be able to access the files
        // both from the host and the container.
        if (DatabaseType == DatabaseType.SQLite)
        {
            foreach (var connectionString in new[] { Configuration.ConnectionString, Configuration.AdminConnectionString })
            {
                var dbFile = connectionString?.Split("=", 2)[1];
                var folder = Path.GetDirectoryName(dbFile)!;
                bindMounts[folder] = folder;
            }
        }

        // Convert configuration to command-line arguments
        var convertToDockerArguments = ConvertToDockerArguments(Configuration);
        var dockerArguments = convertToDockerArguments.ToList();

        // Add the database type
        dockerArguments.Add("--databasetype=" + DatabaseType.ToString().ToLowerInvariant());

        //dockerArguments.Add("--verbosity=debug");

        // Needed when overriding the entrypoint, not the command
        dockerArguments.Insert(0, "./grate");

        var containerBuilder = new ContainerBuilder(DockerImage)
            .WithEntrypoint(dockerArguments.ToArray())
            .WithEnvironment("DOTNET_BUNDLE_EXTRACT_BASE_DIR", "/home/app")
            // This is dependent on changing the image to only use grate as ENTRYPOINT, and the rest as CMD
            //.WithCommand(dockerArguments.ToArray())
            .WithCreateParameterModifier(param => param.HostConfig?.ReadonlyRootfs = true)
            .WithTmpfsMount("/tmp")
            .WithNetwork(Network)
            .WithLogger(Logger);

        foreach (var bindMount in bindMounts)
        {
            containerBuilder = containerBuilder.WithBindMount(bindMount.Key, bindMount.Value);
        }

        using var executionTimeout = new CancellationTokenSource(TimeSpan.FromMinutes(2));
        await DockerMigrationRunner.Run(containerBuilder.Build(), Logger, executionTimeout.Token);
    }

    public GrateConfiguration Configuration { get; private init; } = null!;

    public IGrateMigrator WithConfiguration(GrateConfiguration configuration)
    {
        return this with
        {
            Configuration = configuration with
            {
                // Need to overwrite the output path, as we don't have the same tmp folders on the host as in the container,
                // and the root file system is read-only in the test container
                OutputPath = new DirectoryInfo(Path.Combine("/tmp", "grate-tests-output", Dir.CreateTempSubdirectory().Name)),
            }
        };
    }

    public IGrateMigrator WithConfiguration(Action<GrateConfigurationBuilder> builder)
    {
        var b = GrateConfigurationBuilder.Create(Configuration);
        builder.Invoke(b);
        return this with
        {
            Configuration = b.Build() with
            {
                // Need to overwrite the output path, as we don't have the same tmp folders on the host as in the container,
                // and the root file system is read-only in the test container
                OutputPath = new DirectoryInfo(Path.Combine("/tmp", "grate-tests-output", Dir.CreateTempSubdirectory().Name))
            }
        };
    }

    public IGrateMigrator WithDatabase(IDatabase database) => this with { Database = database };
    public IDatabase? Database { get; set; }


    private List<string> ConvertToDockerArguments(GrateConfiguration configuration)
    {
        List<string> result = new();

        var properties = configuration.GetType().GetProperties();

        var cmd = new MigrateCommand(this);

        foreach (var prop in properties)
        {
            // Skip properties with default values
            var value = prop.GetValue(configuration);
            var defaultValue = prop.GetValue(GrateConfiguration.Default);

            var serializedValue = JsonSerializer.Serialize(value?.ToString(), SerializerOptions);
            var serializedDefault = JsonSerializer.Serialize(defaultValue?.ToString(), SerializerOptions);

            if (serializedValue.Equals(serializedDefault))
            {
                continue;
            }

            // Convert IFoldersConfiguration to string
            if (value is IFoldersConfiguration foldersConfiguration)
            {
                value = string.Join(';', foldersConfiguration.Values);
            }

            var name = prop.Name;
            // In System.CommandLine the option Name now includes the prefix (e.g. "--connectionstring")
            // and Aliases no longer contains the name, so match on the prefix-stripped name and use
            // the option's (always "--"-prefixed) Name as the flag to pass on the command line.
            var option = cmd.Options.FirstOrDefault(o => string.Equals(o.Name.TrimStart('-'), name, StringComparison.OrdinalIgnoreCase));

            if (option is not null && value is not null)
            {
                var optionName = option.Name;

                if (value is string[] arr)
                {
                    result.AddRange(arr.Select(v => $"{optionName}={v}"));
                }
                else
                {
                    result.Add($"{optionName}={value}");
                }
            }
        }

        return result;
#pragma warning restore CS0162 // Unreachable code detected
    }

    private static readonly JsonSerializerOptions SerializerOptions = new(JsonSerializerOptions.Default)
    {
        ReferenceHandler = ReferenceHandler.IgnoreCycles
    };

    public ValueTask DisposeAsync()
    {
        return new ValueTask(Task.CompletedTask);
    }

}

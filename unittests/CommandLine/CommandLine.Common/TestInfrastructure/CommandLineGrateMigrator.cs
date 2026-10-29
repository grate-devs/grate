using System.Diagnostics;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;
using grate.Commands;
using grate.Configuration;
using grate.Exceptions;
using grate.Migration;

namespace CommandLine.Common.TestInfrastructure;

public record CommandLineGrateMigrator(DatabaseType DatabaseType) : IGrateMigrator
{
    public DatabaseType DatabaseType { get; set; } = DatabaseType;

    public async Task Migrate()
    {
        // Convert configuration to command-line arguments
        var convertToCommandLineArguments = ConvertToCommandLineArguments(Configuration);
        var commandLineArguments = convertToCommandLineArguments.ToList();
        
        // Add the database type
        commandLineArguments.Add("--databasetype=" + DatabaseType.ToString().ToLowerInvariant());
        
        
        // Run the command-line tool with the arguments
        #if NET8_0_OR_GREATER
        var processInfo = new ProcessStartInfo(GrateExecutable, commandLineArguments)
        #else
        var processInfo = new ProcessStartInfo(GrateExecutable, string.Join(' ', commandLineArguments))
        #endif
        {
            RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false,
        };

        using var process = Process.Start(processInfo);
        await process!.WaitForExitAsync();
        
        var output = await process.StandardOutput.ReadToEndAsync();
        var error = await process.StandardError.ReadToEndAsync();
        
        var exitCode = process.ExitCode;
        if (exitCode != 0)
        {
            try
            {
                throw new Exception($"grate failed with exit code {exitCode}. Output: {output}. Error: {error}");
            }catch (Exception e)
            {
                throw new MigrationFailed(e);
            }
        }
        
    }

    public GrateConfiguration Configuration { get; private init; } = null!;
    
    public IGrateMigrator WithConfiguration(GrateConfiguration configuration)
    {
        return this with { Configuration = configuration };
    }

    public IGrateMigrator WithConfiguration(Action<GrateConfigurationBuilder> builder)
    {
        var b = GrateConfigurationBuilder.Create(Configuration);
        builder.Invoke(b);
        return this with { Configuration = b.Build() };
    }
    
    public IGrateMigrator WithDatabase(IDatabase database) => this with { Database = database };
    public IDatabase? Database { get; set; }
    
    
    private List<string> ConvertToCommandLineArguments(GrateConfiguration configuration)
    {
        List<string> result = new();

        var properties = configuration.GetType().GetProperties();

        var cmd = new MigrateCommand((_, _) => Task.FromResult(0));

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

    private static string GrateExecutable => 
        Environment.GetEnvironmentVariable("GrateExecutablePath") ??
        typeof(CommandLineGrateMigrator).Assembly.GetCustomAttribute<GrateExecutablePathAttribute>()?.Path 
        ?? throw new Exception("Grate executable path not found");
    

    public ValueTask DisposeAsync()
    {
        return new ValueTask(Task.CompletedTask);
    }
    
}

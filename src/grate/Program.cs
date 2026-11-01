using System.CommandLine;
using System.Reflection;
using grate.Commands;
using grate.Configuration;
using grate.Infrastructure;
using grate.mariadb.DependencyInjection;
using grate.Migration;
using grate.oracle.DependencyInjection;
using grate.postgresql.DependencyInjection;
using grate.sqlite.DependencyInjection;
using grate.sqlserver.DependencyInjection;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Console;

namespace grate;

public static class Program
{
    public static Task<int> Main(string[] args)
    {
        var rootCommand = new MigrateCommand(Migrate)
        {
            Description = $"grate v{GetVersion()} - sql for the 20s"
        };

        // Built-in help and parse-error actions run before the migration action, without
        // constructing database services or binding configuration from invalid input.
        return rootCommand.Parse(args).InvokeAsync(new InvocationConfiguration
        {
            EnableDefaultExceptionHandler = false
        });
    }

    private static async Task<int> Migrate(CommandLineGrateConfiguration config, InvocationConfiguration invocationConfiguration)
    {
        if (config.UpToDateCheck)
        {
            config = config with { Verbosity = LogLevel.Critical, DryRun = true };
        }

        await using var serviceProvider = BuildServiceProvider(config);
        await using var scope = serviceProvider.CreateAsyncScope();
        var logger = scope.ServiceProvider.GetRequiredService<ILogger<GrateMigrator>>();

        int result;
        try
        {
            await scope.ServiceProvider.GetRequiredService<IGrateMigrator>().Migrate();
            result = 0;
        }
        catch (Exception ex)
        {
            result = ExceptionHandler(ex, invocationConfiguration, logger);
        }

        await WaitForLoggerToFinish();
        return result;
    }

    private static int ExceptionHandler(Exception ex, InvocationConfiguration configuration, ILogger logger)
    {
        // Log the error message at the highest level, and the exception at debug level.
        // Avoids logging the exception stack trace to the end user, if logging level is not set to debug.

        configuration.Error.WriteColoredMessage("An error occurred: ", GrateConsoleColor.Foreground.Red);

        logger.LogDebug(ex, "{ErrorMessage}", ex.Message);
        logger.LogError("{ErrorMessage}", ex.Message);

        return 1;
    }


    private static string GetVersion() => Assembly.GetEntryAssembly()?.GetName().Version?.ToString() ?? "1.0.0.1";

    /// <summary>
    /// Wait for logger to be finished - it logs on a different thread, and we
    /// don't want to exit before everything is written to console.
    /// </summary>
    private static async Task WaitForLoggerToFinish()
    {
        var maxWaitTime = 2000;
        var waitedTime = 0;
        var delay = 100;

        await Task.Delay(1);
        try
        {
            while (ThreadPool.PendingWorkItemCount > 0 && waitedTime < maxWaitTime)
            {
                await Task.Delay(delay);
                waitedTime += delay;
            }
        }
        catch (Exception)
        {
            // We don't want to fail on exit. Nevermind, just exit, and get on with it.
        }
    }

    private static ServiceProvider BuildServiceProvider(CommandLineGrateConfiguration config)
    {
        IServiceCollection services = new ServiceCollection();

        services.AddLogging(logging => logging.AddConsole(options =>
            {
                options.FormatterName = GrateConsoleFormatter.FormatterName;
                options.LogToStandardErrorThreshold = LogLevel.Warning;
            })
            .AddFilter("Grate.Migration.Internal", LogLevel.Critical)
            .AddFilter("Grate.Migration.IsUpToDate", LogLevel.Information)
            .SetMinimumLevel(config.Verbosity)
            .AddConsoleFormatter<GrateConsoleFormatter, SimpleConsoleFormatterOptions>());
        
        services = config.DatabaseType switch
        {
            DatabaseType.MariaDB => services.AddGrateWithMariaDb(config),
            DatabaseType.Oracle => services.AddGrateWithOracle(config),
            DatabaseType.PostgreSQL => services.AddGrateWithPostgreSQL(config),
            DatabaseType.SQLServer => services.AddGrateWithSqlServer(config),
            DatabaseType.SQLite => services.AddGrateWithSqlite(config),
            _ => throw new ArgumentOutOfRangeException(nameof(config), 
                config.DatabaseType, 
                "Unknown target database type: " + config.DatabaseType)
        };

        return services.BuildServiceProvider();
    }
}

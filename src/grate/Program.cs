using System.CommandLine;
using System.Reflection;
using grate.Commands;
using grate.bigquery.DependencyInjection;
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
    private static IServiceProvider _serviceProvider = default!;

    public static async Task<int> Main(string[] args)
    {
        // Temporarily parse the configuration, to get the verbosity level, and potentially set parameters
        // to support the "IsUpToDate" check.
        var cfg = ParseGrateConfiguration(args);
        if (cfg.UpToDateCheck)
        {
            cfg = cfg with { Verbosity = LogLevel.Critical, DryRun = true };
        }

        _serviceProvider = BuildServiceProvider(cfg).CreateAsyncScope().ServiceProvider;

        var rootCommand = Create<MigrateCommand>();

        rootCommand.Description = $"grate v{GetVersion()} - sql for the 20s";

        // System.CommandLine enables help, suggestions, typo corrections and parse-error reporting
        // by default. We handle exceptions ourselves (see below), so disable the built-in handler.
        var configuration = new InvocationConfiguration
        {
            EnableDefaultExceptionHandler = false
        };

        var parseResult = rootCommand.Parse(args);

        int result;
        try
        {
            result = await parseResult.InvokeAsync(configuration);
        }
        catch (Exception ex)
        {
            result = ExceptionHandler(ex, configuration);
        }

        await WaitForLoggerToFinish();

        return result;
    }

    private static int ExceptionHandler(Exception ex, InvocationConfiguration configuration)
    {
        // Log the error message at the highest level, and the exception at debug level.
        // Avoids logging the exception stack trace to the end user, if logging level is not set to debug.

        var logger = _serviceProvider.GetRequiredService<ILogger<GrateMigrator>>();

        configuration.Error.WriteColoredMessage("An error occurred: ", GrateConsoleColor.Foreground.Red);

        logger.LogDebug(ex, "{ErrorMessage}", ex.Message);
        logger.LogError("{ErrorMessage}", ex.Message);

        return 1;
    }


    private static string GetVersion() => Assembly.GetEntryAssembly()?.GetName().Version?.ToString() ?? "1.0.0.1";

    private static CommandLineGrateConfiguration ParseGrateConfiguration(IReadOnlyList<string> commandline)
    {
        var cmd = new MigrateCommand(null!);
        var parseResult = cmd.Parse(commandline);
        return cmd.GetConfiguration(parseResult);
    }


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

        services.AddCliCommands();

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
            DatabaseType.BigQuery => services.AddGrateWithBigQuery(config),
            _ => throw new ArgumentOutOfRangeException(nameof(config), 
                config.DatabaseType, 
                "Unknown target database type: " + config.DatabaseType)
        };

        return services.BuildServiceProvider();
    }

    private static T Create<T>() where T : notnull => _serviceProvider.GetRequiredService<T>();
}

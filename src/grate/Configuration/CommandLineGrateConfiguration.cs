using Microsoft.Extensions.Logging;

namespace grate.Configuration;

internal record CommandLineGrateConfiguration : GrateConfiguration
{
    /// <summary>
    /// Database type to use.
    /// </summary>
    public DatabaseType DatabaseType { get; set; }

    public MigrationLogFormat LogFormat { get; init; } = MigrationLogFormat.Auto;

    public LogLevel Verbosity { get; init; } = LogLevel.Information;
}

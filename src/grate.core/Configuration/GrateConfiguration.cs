using grate.Infrastructure;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace grate.Configuration;

/// <summary>
/// Configuration shared by CLI migrations and programmatic use.
/// The CLI maps parsed option values explicitly onto this configuration.
/// </summary>
public record GrateConfiguration
{
    /// <summary>
    /// Set of predefined folder names to use for the migration.
    /// </summary>

    public IFoldersConfiguration? Folders { get; init; } = FoldersConfiguration.Default();
  
    /// <summary>
    /// The folder used by grate to find the scripts. The subfolders must follow the naming convention of grate. See grate default folder structure for more information.
    /// </summary>
    public DirectoryInfo SqlFilesDirectory { get; init; } = CurrentDirectory;

    /// <summary>
    /// Output folder.
    /// </summary>
    public DirectoryInfo OutputPath { get; init; } = new(Path.Combine(CurrentDirectory.FullName, "output"));

    /// <summary>
    /// The connection string to use when connecting to the database. Recommend to use the connection string with the admin privilege, otherwise, you need to provide the admin connection string separately.
    /// </summary>
    public string? ConnectionString { get; set; }

    /// <summary>
    /// Schema name to use for the migration. Defaults to "grate".
    /// </summary>
    public string SchemaName { get; init; } = "grate";

    /// <summary>
    /// Table name to use for storing the migration history. Defaults to "ScriptsRun".
    /// </summary>
    public string ScriptsRunTableName { get; init; } = "ScriptsRun";

    /// <summary>
    /// Table name to use for storing the migration error history. Defaults to "ScriptsRunErrors".
    /// </summary>
    public string ScriptsRunErrorsTableName { get; init; } = "ScriptsRunErrors";

    /// <summary>
    /// Table name to use for storing the migration version. Defaults to "Version".
    /// </summary>
    public string VersionTableName { get; init; } = "Version";

    /// <summary>
    /// The connection string to use when connecting to the database as an admin. This connection string requires the dbo privilege.
    /// Grate will use this connection to create new database if needed.
    /// </summary>
    public string? AdminConnectionString { get; init; }

    public string? AccessToken { get; set; } // consider to remove, looks like sqlserver specific

    public static GrateConfiguration Default => new();

    /// <summary>
    /// Allow grate to create the database if it doesn't exist. User must provide the admin connection string or connectionstring with admin privilege.
    /// Most of the case, grate will try to find the admin connection string from the connection string (if adminconnection string is not provided)
    /// </summary>
    public bool CreateDatabase { get; init; } = true;
    public bool AlterDatabase { get; init; } // not sure if this is needed, consider to remove

    /// <summary>
    /// Tell grate to run the entire migration in a transaction. Defaults to false.
    /// </summary>
    public bool Transaction { get; init; }

    // /// <summary>
    // /// The environment the current migration is targeting for env-specific scripts.
    // /// </summary>
    // public string? Environments { get; init; }

    /// <summary>
    /// The environment the current migration is targeting for env-specific scripts.
    /// </summary>
    public GrateEnvironment? Environment { get; set; }
    // {
    //     get => Environments is {} ? new(Environments) : null;
    //     init => Environments = string.Join(",", value?.Environments ?? []);
    // }


    /// <summary>
    /// The optional repository path value used to track along with version.
    /// </summary>
    public string? RepositoryPath { get; init; }

    /// <summary>
    /// The database version we're migrating to on this run.
    /// </summary>
    public string Version { get; init; } = "0.0.0.1";

    /// <summary>
    /// Set the command timeout for the migration.
    /// </summary>
    public int CommandTimeout { get; init; }
    public int AdminCommandTimeout { get; init; }
    public bool Silent => NonInteractive;

    /// <summary>
    /// Tell grate confirm the migration before running. Default to always ask for the confirmation.
    /// </summary>
    public bool NonInteractive { get; init; }

    /// <summary>
    /// This instructs grate to not perform token replacement {{somename}}. Defaults to false.
    /// </summary>
    public bool DisableTokenReplacement { get; init; }

    /// <summary>
    /// Whether to drop the database prior to migration or not.
    /// </summary>
    public bool Drop { get; init; }

    /// <summary>
    /// If true grate will issue a warning and RUN any one time scripts that have changed.
    /// </summary>
    public bool WarnOnOneTimeScriptChanges { get; init; }

    /// <summary>
    /// If true grate will issue a warning, update the dbase hash but NOT RUN any one time scripts that have changed.
    /// </summary>
    public bool WarnAndIgnoreOnOneTimeScriptChanges { get; init; }

    /// <summary>
    /// The set of user-provided "key=value" pairs for use in token replacement.
    /// </summary>
    public IEnumerable<string>? UserTokens { get; init; }

    private static DirectoryInfo CurrentDirectory => new(Directory.GetCurrentDirectory());

    /// <summary>
    /// If true grate will not store script text in the database to save space in small/embedded databases.
    /// </summary>
    public bool DoNotStoreScriptsRunText { get; init; }

    /// <summary>
    /// If true we mark scripts as run but don't actually run them.
    /// </summary>
    public bool Baseline { get; init; }

    /// <summary>
    /// If true we need to log what we would have done, but NOT run any SQL
    /// including writing to the grate versioning schema
    /// </summary>
    public bool DryRun { get; init; }

    /// <summary>
    /// If true runs all AnyTime scripts even if they haven't changed.
    /// </summary>
    public bool RunAllAnyTimeScripts { get; init; }

    /// <summary>
    /// If specified, location of the backup file to use when restoring
    /// </summary>
    public string? Restore { get; init; }

    /// <summary>
    /// By default, scripts are ordered by relative path including subdirectories. This option searches subdirectories, but order is based on filename alone.
    /// </summary>
    public bool IgnoreDirectoryNames { get; set; }

    /// <summary>
    /// Defer writing to the run tables until the end of the migration (only used in bootstrapping)
    /// </summary>
    internal bool DeferWritingToRunTables { get; set; }

    public bool UpToDateCheck { get; set; }
}

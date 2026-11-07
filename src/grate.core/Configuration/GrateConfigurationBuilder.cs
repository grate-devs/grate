using grate.Infrastructure;

namespace grate.Configuration;

/// <summary>
/// Fluent builder for GrateConfiguration.
/// </summary>
public sealed partial class GrateConfigurationBuilder
{
    private GrateConfiguration _grateConfiguration;

    private GrateConfigurationBuilder(GrateConfiguration? presetGrateConfiguration = null)
    {
        presetGrateConfiguration ??= GrateConfiguration.Default;
        _grateConfiguration = presetGrateConfiguration;
    }

    /// <summary>
    /// Build the grate configuration.
    /// </summary>
    /// <returns>GrateConfiguration</returns>
    public GrateConfiguration Build()
    {
        return _grateConfiguration;
    }

    /// <summary>
    /// Output folder (logs, backups, etc).
    /// </summary>
    /// <param name="outputFolder">Target folder to store logs, backups, etc</param>
    /// <returns>GrateConfigurationBuilder</returns>
    public GrateConfigurationBuilder WithOutputFolder(DirectoryInfo outputFolder)
    {
        _grateConfiguration = _grateConfiguration with { OutputPath = outputFolder };
        return this;
    }
    
    /// <summary>
    /// Output folder (logs, backups, etc).
    /// </summary>
    /// <param name="outputFolder">Target folder to store logs, backups, etc</param>
    /// <returns>GrateConfigurationBuilder</returns>
    public GrateConfigurationBuilder WithOutputFolder(string outputFolder)
    {
        WithOutputFolder(new DirectoryInfo(outputFolder));
        return this;
    }

    /// <summary>
    /// Specify the folder configuration to use for the migration, i.e the
    /// names of the folders and the migration type. Default is the grate default folder configuration,
    /// using 'up', 'functions', 'views', 'sprocs', 'triggers', 'indexes', 'permissions' and 'after_migration'.
    /// </summary>
    /// 
    /// <param name="folders">A folder configuration to use. Can be DefaultConfiguration with some modifications,
    /// a fully customized folder set, or a slightly modified one.
    ///
    /// Please see the static helper class <see cref="Folders"/> with factory methods for creating folder configurations.</param>
    /// 
    /// <returns>GrateConfigurationBuilder</returns>
    public GrateConfigurationBuilder WithFolders(IFoldersConfiguration folders)
    {
        _grateConfiguration = _grateConfiguration with { Folders = folders };
        return this;
    }
    

    /// <summary>
    /// Specify the schema name to use for the migration. Default 'grate'
    /// </summary>
    /// <param name="schemaName">The name of the database schema used for migration.</param>
    /// <returns>GrateConfigurationBuilder</returns>
    public GrateConfigurationBuilder WithSchema(string schemaName)
    {
        _grateConfiguration = _grateConfiguration with { SchemaName = schemaName };
        return this;
    }

    /// <summary>
    /// Specify the folder where the migration scripts are located. Default is the current directory.
    /// </summary>
    /// <param name="sqlFilesDirectory">Directory containing the grate subfolders.</param>
    /// <returns>GrateConfigurationBuilder</returns>
    public GrateConfigurationBuilder WithSqlFilesDirectory(DirectoryInfo sqlFilesDirectory)
    {
        _grateConfiguration = _grateConfiguration with { SqlFilesDirectory = sqlFilesDirectory };
        return this;
    }

    /// <summary>
    /// Specify the folder where the migration scripts are located. Default is the current directory.
    /// </summary>
    /// <param name="sqlFilesDirectory">Directory containing the grate subfolders.</param>
    /// <returns>GrateConfigurationBuilder</returns>
    public GrateConfigurationBuilder WithSqlFilesDirectory(string sqlFilesDirectory)
    {
        WithSqlFilesDirectory(new DirectoryInfo(sqlFilesDirectory));
        return this;
    }

    /// <summary>
    /// Connection string to use when connecting to the database.
    /// </summary>
    /// <param name="connectionString">Database connection string</param>
    /// <returns>GrateConfigurationBuilder</returns>
    public GrateConfigurationBuilder WithConnectionString(string connectionString)
    {
        _grateConfiguration = _grateConfiguration with { ConnectionString = connectionString };
        return this;
    }

    /// <summary>
    /// Connection string with admin privileges. Used to create new database if needed.
    /// Defaults to the same as the connection string.
    /// </summary>
    /// <param name="adminConnectionString">Admin connection string</param>
    /// <returns>GrateConfigurationBuilder</returns>
    public GrateConfigurationBuilder WithAdminConnectionString(string adminConnectionString)
    {
        _grateConfiguration = _grateConfiguration with { AdminConnectionString = adminConnectionString };
        return this;
    }

    /// <summary>
    /// Repository path of service to use. Grate will store the repository path in the database
    /// for history and tracking purposes.
    /// </summary>
    /// <param name="repositoryPath">service migration repository path</param>
    /// <returns>GrateConfigurationBuilder</returns>
    public GrateConfigurationBuilder WithRepositoryPath(string repositoryPath)
    {
        _grateConfiguration = _grateConfiguration with { RepositoryPath = repositoryPath };
        return this;
    }

    /// <summary>
    /// Version of service to use. Grate will store the version in the database
    /// for history and tracking purposes.
    /// </summary>
    /// <param name="version">service migration version</param>
    /// <returns>GrateConfigurationBuilder</returns>
    public GrateConfigurationBuilder WithVersion(string version)
    {
        _grateConfiguration = _grateConfiguration with { Version = version };
        return this;
    }

    /// <summary>
    /// Tell grate do not create any database. This will make the migration fail if the database does not exist.
    /// </summary>
    /// <returns>GrateConfigurationBuilder</returns>
    public GrateConfigurationBuilder DoNotCreateDatabase()
    {
        _grateConfiguration = _grateConfiguration with { CreateDatabase = false };
        return this;
    }
    
    /// <summary>
    /// Run the migration in a transaction. Note that this is not supported by all databases.
    /// </summary>
    /// <returns>GrateConfigurationBuilder</returns>
    public GrateConfigurationBuilder WithTransaction(bool runInTransaction = true)
    {
        _grateConfiguration = _grateConfiguration with { Transaction = runInTransaction };
        return this;
    }
    
    /// <summary>
    /// Set migration environment. This is used to run environment-specific scripts.
    /// </summary>
    /// <param name="environmentName">Environment name to run</param>
    /// <returns>GrateConfigurationBuilder</returns>
    public GrateConfigurationBuilder WithEnvironment(string? environmentName)
    {
        if (environmentName != null)
        {
            _grateConfiguration = _grateConfiguration with { Environment = new GrateEnvironment(environmentName) };
        }
        return this;
    }
    
    /// <summary>
    /// Do not store the text of the run scripts in the migration history table.
    /// This can save space, in very small environments (e.g. embedded)
    /// </summary>
    /// <returns>GrateConfigurationBuilder</returns>
    public GrateConfigurationBuilder DoNotStoreScriptsRunText()
    {
        _grateConfiguration = _grateConfiguration with { DoNotStoreScriptsRunText = true };
        return this;
    }
    
    /// <summary>
    /// Run all anytime scripts, even if they have not changed
    /// </summary>
    /// <returns></returns>
    public GrateConfigurationBuilder RunAllAnyTimeScripts()
    {
        _grateConfiguration = _grateConfiguration with { RunAllAnyTimeScripts = true };
        return this;
    }
    
    /// <summary>
    /// Drop the database before running the migration.
    /// </summary>
    /// <returns></returns>
    public GrateConfigurationBuilder DropDatabase()
    {
        _grateConfiguration = _grateConfiguration with { Drop = true };
        return this;
    }
    
    /// <summary>
    /// Do not run the migration, just print what would be run.
    /// </summary>
    /// <returns></returns>
    public GrateConfigurationBuilder DryRun()
    {
        _grateConfiguration = _grateConfiguration with { DryRun = true };
        return this;
    }
    
    /// <summary>
    /// Run in baseline mode. This will not run any scripts, just store the current version as the baseline.
    /// </summary>
    /// <returns></returns>
    public GrateConfigurationBuilder Baseline()
    {
        _grateConfiguration = _grateConfiguration with { Baseline = true };
        return this;
    }
      
    /// <summary>
    /// Set the command timeout for the migration. Default is 30 seconds. 
    /// </summary>
    /// <returns></returns>
    public GrateConfigurationBuilder CommandTimeout(int commandTimeout)
    {
        _grateConfiguration = _grateConfiguration with { CommandTimeout = commandTimeout };
        return this;
    }
    
    /// <summary>
    /// Set the admin command timeout for the migration. Default is 30 seconds. 
    /// </summary>
    /// <returns></returns>
    public GrateConfigurationBuilder AdminCommandTimeout(int timeout)
    {
        _grateConfiguration = _grateConfiguration with { AdminCommandTimeout = timeout };
        return this;
    }
    
    /// <summary>
    /// Only warn if a one-time script has changed between runs.
    /// The default is to fail the migration if a one-time script has changed.
    /// </summary>
    /// <returns></returns>
    public GrateConfigurationBuilder WarnOnOneTimeScriptChanges(bool warn = true)
    {
        _grateConfiguration = _grateConfiguration with { WarnOnOneTimeScriptChanges = warn };
        return this;
    }
    
    /// <summary>
    /// Only warn if a one-time script has changed between runs, and IGNORE the script (do not run it).
    /// Update the hash in the database to match the current script, so it will not be run again.
    /// </summary>
    /// <returns></returns>
    public GrateConfigurationBuilder WarnAndIgnoreOnOneTimeScriptChanges(bool warn = true)
    {
        _grateConfiguration = _grateConfiguration with { WarnAndIgnoreOnOneTimeScriptChanges = warn };
        return this;
    }
    
    /// <summary>
    /// Set the user tokens to use for the migration. This is used to replace tokens in the migration scripts.
    /// provide a list of tokens in the form "token=value".
    /// </summary>
    /// <returns></returns>
    public GrateConfigurationBuilder WithUserTokens(params string[] tokens)
    {
        _grateConfiguration = _grateConfiguration with { UserTokens = tokens };
        return this;
    }
    
    /// <summary>
    /// Set the user tokens to use for the migration. This is used to replace tokens in the migration scripts.
    /// provide a key-value pair of tokens.
    /// </summary>
    /// <returns></returns>
    public GrateConfigurationBuilder WithUserTokens(IDictionary<string, string> tokens)
    {
        var tokenStrings = tokens.Select(t => $"{t.Key}={t.Value}").ToArray();
        _grateConfiguration = _grateConfiguration with { UserTokens = tokenStrings };
        return this;
    }
    
    /// <summary>
    /// Restore the database from a backup before running the migration.
    /// </summary>
    /// <returns></returns>
    public GrateConfigurationBuilder RestoreFrom(string backupPath)
    {
        _grateConfiguration = _grateConfiguration with { Restore = backupPath };
        return this;
    }

    /// <summary>
    /// Set the optional SQL Server file mappings for the backup specified by <see cref="RestoreFrom"/>.
    /// </summary>
    public GrateConfigurationBuilder WithRestoreMoves(params RestoreFileMove[] moves)
    {
        ArgumentNullException.ThrowIfNull(moves);
        _grateConfiguration = _grateConfiguration with { RestoreMoves = Array.AsReadOnly(moves.ToArray()) };
        return this;
    }
    
}

using System.CommandLine;
using grate.Configuration;
using Microsoft.Extensions.Logging;
using static grate.Configuration.DefaultConfiguration;

namespace grate.Commands;

internal sealed class MigrateCommand : RootCommand
{

    public MigrateCommand(Func<CommandLineGrateConfiguration, InvocationConfiguration, Task<int>> migrate) : base("Migrates the database")
    {
        // System.CommandLine's RootCommand adds a built-in --version option by default.
        // grate uses --version for its own purpose (the database version being migrated to),
        // so remove the built-in one to avoid a conflicting option name.
        foreach (var versionOption in Options.OfType<VersionOption>().ToList())
        {
            Options.Remove(versionOption);
        }

        Options.Add(ConnectionString);
        Options.Add(AdminConnectionString);
        Options.Add(SqlFilesDirectory);
        Options.Add(OutputPath);
        Options.Add(Folders);
        Options.Add(AccessToken);
        Options.Add(CommandTimeout);
        Options.Add(CommandTimeoutAdmin);
        Options.Add(DatabaseType);
        Options.Add(RunInTransaction);
        Options.Add(Environments);
        Options.Add(SchemaName);
        Options.Add(Silent);
        Options.Add(RepositoryPath);
        Options.Add(Version);
        Options.Add(Drop);
        Options.Add(CreateDatabase);
        Options.Add(Tokens); //DisableTokenReplacement
        Options.Add(WarnAndRunOnScriptChange);
        Options.Add(WarnAndIgnoreOnScriptChange);
        Options.Add(UserTokens);
        Options.Add(DoNotStoreScriptText);
        Options.Add(Baseline);
        Options.Add(RunAllAnyTimeScripts);
        Options.Add(DryRun);
        Options.Add(Restore);
        Options.Add(IgnoreDirectoryNames);
        Options.Add(UpToDateCheck);
        Options.Add(Verbosity);
        Subcommands.Add(new SkillsCommand());

        // Obsolete options - kept so that grate keeps reporting helpful messages, but not bound.
        Options.Add(Database);
        Options.Add(ServerName);

        SetAction((result, _) => migrate(GetConfiguration(result), result.InvocationConfiguration));
    }

    /// <summary>
    /// Reads the parsed option values and maps them onto a <see cref="CommandLineGrateConfiguration"/>.
    /// This is the explicit replacement for the convention-based model binder that used to live in
    /// System.CommandLine.NamingConventionBinder.
    /// </summary>
    public CommandLineGrateConfiguration GetConfiguration(ParseResult parseResult)
    {
        // Preserve configuration defaults for optional values without a default value factory.
        var defaults = new CommandLineGrateConfiguration();

        return new CommandLineGrateConfiguration
        {
            ConnectionString = parseResult.GetValue(ConnectionString),
            AdminConnectionString = parseResult.GetValue(AdminConnectionString),
            SqlFilesDirectory = parseResult.GetValue(SqlFilesDirectory)!,
            OutputPath = parseResult.GetValue(OutputPath)!,
            Folders = parseResult.GetValue(Folders) ?? defaults.Folders,
            AccessToken = parseResult.GetValue(AccessToken),
            CommandTimeout = parseResult.GetValue(CommandTimeout),
            AdminCommandTimeout = parseResult.GetValue(CommandTimeoutAdmin),
            DatabaseType = parseResult.GetValue(DatabaseType),
            Transaction = parseResult.GetValue(RunInTransaction),
            Environment = parseResult.GetValue(Environments),
            SchemaName = parseResult.GetValue(SchemaName)!,
            NonInteractive = parseResult.GetValue(Silent),
            RepositoryPath = parseResult.GetValue(RepositoryPath),
            Version = parseResult.GetValue(Version) ?? defaults.Version,
            Drop = parseResult.GetValue(Drop),
            CreateDatabase = parseResult.GetValue(CreateDatabase),
            DisableTokenReplacement = parseResult.GetValue(Tokens),
            WarnOnOneTimeScriptChanges = parseResult.GetValue(WarnAndRunOnScriptChange),
            WarnAndIgnoreOnOneTimeScriptChanges = parseResult.GetValue(WarnAndIgnoreOnScriptChange),
            UserTokens = parseResult.GetValue(UserTokens),
            DoNotStoreScriptsRunText = parseResult.GetValue(DoNotStoreScriptText),
            Baseline = parseResult.GetValue(Baseline),
            RunAllAnyTimeScripts = parseResult.GetValue(RunAllAnyTimeScripts),
            DryRun = parseResult.GetValue(DryRun),
            Restore = parseResult.GetValue(Restore),
            IgnoreDirectoryNames = parseResult.GetValue(IgnoreDirectoryNames),
            UpToDateCheck = parseResult.GetValue(UpToDateCheck),
            // Verbosity has no default value factory; when it isn't supplied keep the record default.
            Verbosity = parseResult.GetResult(Verbosity) is { Implicit: false }
                ? parseResult.GetValue(Verbosity)
                : defaults.Verbosity,
        };
    }

    //REQUIRED OPTIONS
    private readonly Option<string> ConnectionString =
        new("--connectionstring", "-c", "-cs", "--connstring")
        {
            Description = "You now provide an entire connection string. ServerName and Database are obsolete.",
            Required = true
        };


    //CONNECTIONSTRING OPTIONS
    private readonly Option<string> AdminConnectionString =
        new("--adminconnectionstring", "-csa", "-a", "-acs", "--adminconnstring")
        {
            Description = "The connection string for connecting to master, if you want to create the database.  Defaults to the same as --connstring.",
            Required = false
        };


    //DIRECTORY OPTIONS
    private readonly Option<DirectoryInfo> SqlFilesDirectory =
        new Option<DirectoryInfo>("--sqlfilesdirectory", "-f", "--files")
        {
            Description = "The directory where your SQL scripts are",
            DefaultValueFactory = _ => new DirectoryInfo(DefaultFilesDirectory)
        }.AcceptExistingOnly();

    private readonly Option<DirectoryInfo> OutputPath =
        new("--outputPath", "-o", "--output")
        {
            Description = "This is where everything related to the migration is stored. This includes any backups, all items that ran, permission dumps, logs, etc.",
            DefaultValueFactory = _ => new DirectoryInfo(DefaultOutputPath)
        };

    private readonly Option<IFoldersConfiguration?> Folders =
        new("--folders")
        {
            CustomParser = result =>
                FoldersCommand.Parse(result.Tokens.Count > 0 ? result.Tokens[0].Value : null),
            Description =
@"Folder configuration.

If you wish to override any of the default folder names, supply a semicolon separated list of mappings.
You can also specify a file name that has the same contents as you would supply on the command line,
if you find it cumbersome to write all the folders on the command line.

Example:

  --folders 'up=ddl;views=projections;beforemigration=preparefordeploy'

or

  --folders myfolderconfig.txt

,and put the following content in `myfolderconfig.txt`(either semicolon or newline separated)


up=ddl
views=projections
beforemigration=preparefordeploy


this will keep the default folder configuration, but change the names of the folders you supply.

If you want to fully customise the folders, you can do this by specifying a list of folders with keys
that are not among the default folders. Then none of the default folders will be configured, just the ones you supply.

Example:

  --folders folder1=path:a/sub/folder/here,type:Once,connectionType:Admin;folder2=type:EveryTime;folder3=type:AnyTime

The properties you can set per folder, are:

  * Name - the key/name you wish to give to the folder (doesn't matter if path is specified)
  * Path - the relative path of the folder, relative to the --sqlfilesdirectory parameter.
         Defaults to the name given above.
  * Type - the type of the migration (Once, EveryTime, Anytime), defaults to Once,
  * ConnectionType - whether to run on the default connection, or on the admin (defaults to Default),
                   Allowed values: default, admin
  * TransactionHandling - whether to be part of the transaction, or run the script even on a rollback,
                        defaults to Default
                        Allowed values: default, autonomous

There are also short forms, if you just wish to supply the folder name or the migration type.

Example:

  --folders folder1=my/first/scripts;folder2=the/last/ones;folder3=something/i/forgot

or

  --folders folder1=Once;folder2=Everytime;folder3=Anytime

the last one will expect the folders to be named 'folder1', 'folder2', and 'folder3', in the sqlfilesdirectory.

"
        };


    //SECURITY OPTIONS
    private readonly Option<string> AccessToken =
        new("--accesstoken")
        {
            Description = "Access token to be used for logging in to SQL Server / Azure SQL Database."
        };


    //TIMEOUT OPTIONS
    private readonly Option<int> CommandTimeout =
        new("--commandtimeout", "-ct")
        {
            Description = "This is the timeout when commands are run. This is not for admin commands or restore.",
            DefaultValueFactory = _ => DefaultCommandTimeout
        };

    private readonly Option<int> CommandTimeoutAdmin =
        new("--admincommandtimeout", "-cta")
        {
            Description = "This is the timeout when administration commands are run (except for restore, which has its own).",
            DefaultValueFactory = _ => DefaultAdminCommandTimeout
        };

    //DATABASE OPTIONS
    private readonly Option<DatabaseType> DatabaseType =
        new("--databasetype", "--dt", "--dbt")
        {
            Description = "TELLS GRATE WHAT TYPE OF DATABASE IT IS RUNNING ON.",
            DefaultValueFactory = _ => Configuration.DatabaseType.SQLServer
        };

    private readonly Option<bool> RunInTransaction =
        new("--transaction", "--trx", "-t")
        {
            Description = "Run the migration in a transaction"
        };

    private readonly Option<string> SchemaName =
        new("--schemaname", "--sc", "--schema")
        {
            Description = "The schema to use for the migration tables",
            DefaultValueFactory = _ => "grate"
        };

    private readonly Option<bool> Drop =
        new("--drop")
        {
            Description = "Drop - This instructs grate to remove the target database.  Unlike RoundhousE grate will continue to run the migration scripts after the drop."
        };

    private readonly Option<bool> CreateDatabase =
        new("--createdatabase", "--create")
        {
            Description = "Create - This instructs grate to create the target database if it does not exist.  Defaults to true.  Set to false to emulate the --donotcreatedatabase flag in roundhouse.",
            DefaultValueFactory = _ => true
        };


    //ENVIRONMENT OPTIONS
    private readonly Option<CommandLineGrateEnvironment?> Environments =
        new("--environment", "--env")
        {
            // A custom parser is needed to support combining environments separated by space, ',' or ';'.
            CustomParser = ArgumentParsers.ParseEnvironment,
            Description =
                "Environment Name - This allows grate to be environment aware and only run scripts that are in a particular environment based on the name of the script.  'something.ENV.LOCAL.sql' would only be run if --env=LOCAL was set.",
            AllowMultipleArgumentsPerToken = true,
            Arity = ArgumentArity.ZeroOrMore
        };


    //WARNING OPTIONS
    private readonly Option<bool> WarnAndRunOnScriptChange =
        new("--warnononetimescriptchanges", "-w")
        {
            Description = "WarnOnOneTimeScriptChanges - Instructs grate to execute changed one time scripts(DDL / DML in Up folder) that have previously been run against the database instead of failing.  A warning is logged for each one time script that is rerun. Defaults to false."
        };

    private readonly Option<bool> WarnAndIgnoreOnScriptChange =
        new("--warnandignoreononetimescriptchanges")
        {
            Description = "WarnAndIgnoreOnOneTimeScriptChanges - Instructs grate to ignore and update the hash of changed one time scripts (DDL/DML in Up folder) that have previously been run against the database instead of failing. A warning is logged for each one time scripts that is rerun. Defaults to false."
        };


    //TOKEN OPTIONS
    private readonly Option<bool> Tokens =
        new("--disabletokenreplacement", "--disabletokens")
        {
            Description = "Tokens - This instructs grate to not perform token replacement ({{somename}}). Defaults to false."
        };

    private static Option<IEnumerable<string>> UserTokens =
        new("--usertokens", "--ut")
        {
            Description = "User Tokens - Allows grate to perform token replacement on custom tokens ({{my_token}}). Set as a key=value pair, eg '--ut=my_token=myvalue'. Can be specified multiple times."
        };


    //SCRIPT OPTIONS
    private readonly Option<bool> DoNotStoreScriptText =
        new("--donotstorescriptsruntext")
        {
            Description = "DoNotStoreScriptsRunText - This instructs grate to not store the full script text in the database. Defaults to false."
        };

    private readonly Option<bool> RunAllAnyTimeScripts =
        new("--runallanytimescripts", "--forceanytimescripts")
        {
            Description = "RunAllAnyTimeScripts - This instructs grate to run any time scripts every time it is run even if they haven't changed. Defaults to false."
        };


    //MISC OPTIONS
    private readonly Option<bool> Baseline =
        new("--baseline")
        {
            Description = "Baseline - This instructs grate to mark the scripts as run, but not to actually run anything against the database. Use this option if you already have scripts that have been run through other means (and BEFORE you start the new ones)."
        };

    private readonly Option<bool> DryRun =
        new("--dryrun")
        {
            Description = " DryRun - This instructs grate to log what would have run, but not to actually run anything against the database.  Use this option if you are trying to figure out what grate is going to do."
        };

    private readonly Option<string> Restore =
        new("--restore")
        {
            Description = " Restore - This instructs grate where to get the backed up database file. Defaults to NULL."
        };

    private readonly Option<bool> Silent =
        new("--noninteractive", "-ni", "--ni", "--silent")
        {
            Description = "Silent - tells grate not to ask for any input when it runs."
        };

    private readonly Option<string> RepositoryPath =
        new("--repositorypath", "-r", "--repo")
        {
            Description = "Repository Path - The repository. A string that can be anything. Used to track versioning along with the version. Defaults to NULL."
        };

    private readonly Option<string> Version =
        new("--version")
        {
            Description = "Database Version - specify the version of the current migration directly on the command line."
        };


    //OBSOLETE OPTIONS
    private readonly Option<string> Database =
        new("--database")
        {
            Description = "OBSOLETE: Please specify the connection string instead",
            Required = false
        };

    private readonly Option<string> ServerName =
        new("--servername", "--instance", "--server", "-s")
        {
            Description = "OBSOLETE: Please specify the connection string instead."
        };

    private readonly Option<bool> IgnoreDirectoryNames =
        new("--ignoredirectorynames", "--searchallinsteadoftraverse", "--searchallsubdirectoriesinsteadoftraverse")
        {
            Description = "IgnoreDirectoryNames - By default, scripts are ordered by relative path including subdirectories. This option searches subdirectories, but order is based on filename alone."
        };

    private readonly Option<bool> UpToDateCheck =
        new("--uptodatecheck", "--isuptodate")
        {
            Description = "Outputs whether the database is up to date or not (whether any non-everytime scripts would be run)"
        };

    private readonly Option<LogLevel> Verbosity =
        new("--verbosity", "-v")
        {
            Description = "Verbosity level (as defined here: https://docs.microsoft.com/dotnet/api/Microsoft.Extensions.Logging.LogLevel)"
        };
}

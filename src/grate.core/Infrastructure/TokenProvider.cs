using grate.Configuration;
using grate.Migration;
#if NETSTANDARD2_0
using static grate.Compatibility.StringSplitOptionsShim;
#else
using static System.StringSplitOptions;
#endif

namespace grate.Infrastructure;

internal class TokenProvider
{
    private readonly GrateConfiguration _config;
    private readonly IDatabase _db;

    public TokenProvider(GrateConfiguration config, IDatabase db)
    {
        _config = config;
        _db = db;
    }

    /// <summary>
    /// Gets a dictionary of tokens for replacement.  Keys == {tokens} and values are their replacement value.
    /// </summary>
    /// <returns></returns>
    public Dictionary<string, string?> GetTokens()
    {
        var tokens = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase)
        {
            // we're missing many of the original roundhouse tokens atm, leaving
            // them commented out as a reminder for future us!

            // I'm not sure some of them make sense (eg Debug), but if they're avail ¯\_(ツ)_/¯

            ["AfterMigrationFolderName"] = GetFolder(KnownFolderKeys.AfterMigration).ToToken(),
            ["AlterDatabaseFolderName"] = GetFolder(KnownFolderKeys.AlterDatabase).ToToken(),
            ["Baseline"] = _config.Baseline.ToString(),
            ["BeforeMigrationFolderName"] = GetFolder(KnownFolderKeys.BeforeMigration).ToToken(),
            ["CommandTimeout"] = _config.CommandTimeout.ToString(),
            ["CommandTimeoutAdmin"] = _config.AdminCommandTimeout.ToString(),
            //["ConfigurationFile"] = ConfigurationFile.to_string(),
            ["ConnectionString"] = _config.ConnectionString,
            ["ConnectionStringAdmin"] = _db.GetAdminConnectionString(_config),
            //["CreateDatabaseCustomScript"] = CreateDatabaseCustomScript.to_string(),
            ["DatabaseName"] = _db.DatabaseName,
            ["DatabaseType"] = _db.DatabaseType,
            //["Debug"] = Debug.to_string(),
            //["DisableOutput"] = DisableOutput.to_string(),
            ["DisableTokenReplacement"] = _config.DisableTokenReplacement.ToString(),
            ["DoNotAlterDatabase"] = (!_config.AlterDatabase).ToString(),
            ["DoNotCreateDatabase"] = (!_config.CreateDatabase).ToString(),
            ["DoNotStoreScriptsRunText"] = _config.DoNotStoreScriptsRunText.ToString(),
            //["DownFolderName"] = _config.Folders?.Down.ToToken(),
            ["Drop"] = _config.Drop.ToString(),
            ["DryRun"] = _config.DryRun.ToString(),
            ["EnvironmentName"] = _config.Environment?.Current,
            ["EnvironmentNames"] = _config.Environment?.Current,  //string.Join(",", EnvironmentNames),
            ["FunctionsFolderName"] = GetFolder(KnownFolderKeys.Functions).ToToken(),
            ["IndexesFolderName"] = GetFolder(KnownFolderKeys.Indexes).ToToken(),
            //["Initialize"] = Initialize.to_string(),
            ["OutputPath"] = _config.OutputPath.FullName, //TODO: Does RH use name or full path?
            ["PermissionsFolderName"] = GetFolder(KnownFolderKeys.Permissions).ToToken(),
            //["RecoveryMode"] = RecoveryMode.to_string(),
            ["RepositoryPath"] = _config.RepositoryPath,
            ["Restore"] = _config.Restore,
            //["RestoreTimeout"] = RestoreTimeout.to_string(),
            ["RunAfterCreateDatabaseFolderName"] = GetFolder(KnownFolderKeys.RunAfterCreateDatabase).ToToken(),
            ["RunAfterOtherAnyTimeScriptsFolderName"] = GetFolder(KnownFolderKeys.RunAfterOtherAnyTimeScripts).ToToken(),
            ["RunAllAnyTimeScripts"] = _config.RunAllAnyTimeScripts.ToString(),
            ["RunBeforeUpFolderName"] = GetFolder(KnownFolderKeys.RunBeforeUp).ToToken(),
            ["RunFirstAfterUpFolderName"] = GetFolder(KnownFolderKeys.RunFirstAfterUp).ToToken(),
            ["SchemaName"] = _config.SchemaName,
            ["ScriptsRunErrorsTableName"] = _db.ScriptsRunErrorsTable,
            ["ScriptsRunTableName"] = _db.ScriptsRunTable,
            //["SearchAllSubdirectoriesInsteadOfTraverse"] = SearchAllSubdirectoriesInsteadOfTraverse.to_string(),
            ["ServerName"] = _db.ServerName,
            ["Silent"] = _config.Silent.ToString(),
            ["SprocsFolderName"] = GetFolder(KnownFolderKeys.Sprocs).ToToken(),
            ["SqlFilesDirectory"] = _config.SqlFilesDirectory.FullName, //TODO: Does RH do full path or just dir name?
            ["TriggersFolderName"] = GetFolder(KnownFolderKeys.Triggers).ToToken(),
            ["UpFolderName"] = GetFolder(KnownFolderKeys.Up).ToToken(),
            ["Version"] = _config.Version,
            //["VersionFile"] = VersionFile.to_string(),
            ["VersionTableName"] = _db.VersionTable,
            //["VersionXPath"] = VersionXPath.to_string(),
            ["ViewsFolderName"] = GetFolder(KnownFolderKeys.Views).ToToken(),
            ["WarnAndIgnoreOnOneTimeScriptChanges"] = _config.WarnAndIgnoreOnOneTimeScriptChanges.ToString(),
            ["WarnOnOneTimeScriptChanges"] = _config.WarnOnOneTimeScriptChanges.ToString(),
            ["WithTransaction"] = _config.Transaction.ToString()
        };

        foreach (var s in _config.UserTokens.Safe()) // s is the original "key=value" value from the user
        {
            (string key, string value) = ParseUserToken(s);
            tokens[key] = value;
        }

        return tokens;
    }

    private MigrationsFolder? GetFolder(string folderKey)
    {
        MigrationsFolder? folder = default;
        _config.Folders?.TryGetValue(folderKey, value: out folder);
        return folder;
    }


    public static (string key, string value) ParseUserToken(string userToken)
    {
        // Splits the given "key=value" string into it's component parts... if there's `=` signs in the value
        // we just return it as is for #641
        var parts = userToken.Split('=', 2, RemoveEmptyEntries | TrimEntries);
        if (parts.Length != 2)
        {
            throw new ArgumentOutOfRangeException(nameof(userToken), $"Failed to parse provided user token '{userToken}'");
        }

        return (parts[0], parts[1]);
    }
}

